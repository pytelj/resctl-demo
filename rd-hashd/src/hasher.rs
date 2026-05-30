// Copyright (c) Facebook, Inc. and its affiliates.
use anyhow::Result;
use crossbeam::channel::{self, select, Receiver, Sender};
use csv::Reader;
use log::{debug, warn};
use pid::Pid;
use quantiles::ckms::CKMS;
use rand::rngs::SmallRng;
use rand::SeedableRng;
use rand_distr::{Distribution, Normal};
use sha1_smol::{Digest, Sha1};
use std::fs::File;
use std::path::Path;
use std::thread::{sleep, spawn, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rd_hashd_intf::{Latencies, Params, Stat};

use super::logger::Logger;
use super::testfiles::TestFiles;
use super::workqueue::WorkQueue;

fn fib_burn(iters: u64, cpu_ratio: f64) -> u64 {
    let rounds = ((iters as f64) * cpu_ratio.max(0.01)).round().max(1.0) as u64;
    let mut a = 0u64;
    let mut b = 1u64;

    for _ in 0..rounds {
        let c = a.wrapping_add(b);
        a = b;
        b = c;
    }

    b
}

pub struct Hasher {
    buf: Vec<u8>,
    cpu_ratio: f64,
    fake_cpu_load_time_per_byte: f64,
}

impl Hasher {
    pub fn new(cpu_ratio: f64, fake_cpu_load_time_per_byte: f64) -> Self {
        Self {
            buf: Vec::new(),
            cpu_ratio,
            fake_cpu_load_time_per_byte,
        }
    }

    pub fn load<P: AsRef<Path>>(
        &mut self,
        _path: P,
        _input_off: u64,
        input_size: usize,
        _is_write: bool,
    ) -> Result<usize> {
        let len = self.buf.len();
        self.buf.resize(len + input_size, 0x5a);
        Ok(input_size)
    }

    pub fn append(&mut self, data: &[u8]) {
        self.buf.extend_from_slice(data);
    }

    pub fn sha1(&mut self) -> Digest {
        if self.fake_cpu_load_time_per_byte > 0.0 {
            sleep(Duration::from_secs_f64(
                self.buf.len() as f64 * self.cpu_ratio * self.fake_cpu_load_time_per_byte,
            ));
            return Default::default();
        }

        let mut repeat = self.cpu_ratio;
        let mut hasher = Sha1::new();
        while repeat > 0.01 {
            if repeat < 0.99 {
                let len = (self.buf.len() as f64 * repeat).round() as usize;
                self.buf.resize(len.max(1), 0);
                repeat = 0.0;
            } else {
                repeat -= 1.0;
            }
            hasher.update(&self.buf);
        }
        hasher.digest()
    }
}

/// Normal distribution with clamps. The portion of the distribution which is
/// cut off by the clamps uniformly raises the distribution within the clamps.
struct ClampedNormal {
    normal: Normal<f64>,
    left: f64,
    right: f64,
}

impl ClampedNormal {
    fn new(mean: f64, stdev: f64, left: f64, right: f64) -> Self {
        assert!(left <= right, "ClampedNormal left={} right={}", left, right);
        Self {
            normal: Normal::new(mean, stdev).unwrap(),
            left,
            right,
        }
    }

    fn sample<R: rand::Rng + ?Sized>(&self, rng: &mut R) -> f64 {
        self.normal.sample(rng).max(self.left).min(self.right)
    }
}

/// Commands from user to the dispatch thread.
pub enum DispatchCmd {
    SetParams(Params),
    GetStat(Sender<Stat>),
    FillAnon,
}

/// Worker completion for the dispatch thread.
struct WorkCompletion {
    started_at: Instant,
}

struct TraceReader {
    launches: Vec<u32>,
    launch_scale: u32,
}

impl TraceReader {
    fn new(trace_path: &str, launch_scale: u32) -> Result<Self> {
        let file = File::open(trace_path)?;
        let mut rdr = Reader::from_reader(file);
        let mut launches = Vec::new();

        for record in rdr.records() {
            let record = record?;
            let launch = record
                .get(2)
                .ok_or_else(|| anyhow::anyhow!("missing third CSV column in {}", trace_path))?
                .parse::<u32>()?;
            launches.push(launch);
        }

        if launches.is_empty() {
            anyhow::bail!("trace file {} contained no samples", trace_path);
        }

        Ok(Self {
            launches,
            launch_scale: launch_scale.max(1),
        })
    }

    fn len(&self) -> usize {
        self.launches.len()
    }

    fn launches_at(&self, idx: usize) -> u32 {
        self.launches[idx % self.launches.len()].saturating_mul(self.launch_scale)
    }
}

/// Dispatch thread which is started when Dispatch is created and
/// keeps scheduling workers according to params.
struct DispatchThread {
    params: Params,
    params_at: Instant,
    logger: Option<Logger>,
    cmd_rx: Receiver<DispatchCmd>,
    trace: Option<TraceReader>,
    trace_start_at: Option<f64>,
    trace_next_at: Instant,
    trace_next_idx: usize,

    wq: WorkQueue,
    cmpl_tx: Sender<WorkCompletion>,
    cmpl_rx: Receiver<WorkCompletion>,

    work_iters_normal: ClampedNormal,
    sleep_normal: ClampedNormal,

    lat_min: f64,
    lat_max: f64,
    ckms: CKMS<f64>,
    ckms_at: Instant,

    lat_pid: Pid<f64>,
    rps_pid: Pid<f64>,

    lat: Latencies,
    concurrency_max: f64,
    concurrency: f64,
    nr_in_flight: u32,
    nr_done: u64,
    last_nr_done: u64,
    rps: f64,
}

impl DispatchThread {
    const WQ_IDLE_TIMEOUT: f64 = 60.0;
    const CKMS_ERROR: f64 = 0.001;

    fn work_iters_normal(params: &Params) -> ClampedNormal {
        let mean = (params.file_size_mean as f64).max(1.0);
        let stdev = (mean * params.file_size_stdev_ratio).max(1.0);
        ClampedNormal::new(mean, stdev, 1.0, (2.0 * mean).max(2.0))
    }

    fn sleep_normal(params: &Params) -> ClampedNormal {
        let sleep_mean = params.sleep_mean.max(0.0);
        let sleep_stdev = (params.sleep_mean * params.sleep_stdev_ratio).max(0.0);
        ClampedNormal::new(sleep_mean, sleep_stdev, 0.0, (2.0 * sleep_mean).max(0.0))
    }

    fn pid_controllers(params: &Params) -> (Pid<f64>, Pid<f64>) {
        let lat = &params.lat_pid;
        let rps = &params.rps_pid;

        (
            {
                let mut lat_pid = Pid::new(1.0, 1.0);
                lat_pid.p(lat.kp, 0.1);
                lat_pid.i(lat.ki, 0.1);
                lat_pid.d(lat.kd, 0.1);
                lat_pid
            },
            {
                let mut rps_pid = Pid::new(1.0, 1.0);
                rps_pid.p(rps.kp, 1.0);
                rps_pid.i(rps.ki, 1.0);
                rps_pid.d(rps.kd, 1.0);
                rps_pid
            },
        )
    }

    fn new(
        params: Params,
        logger: Option<Logger>,
        cmd_rx: Receiver<DispatchCmd>,
        trace_path: Option<String>,
        trace_launch_scale: u32,
        trace_start_at: Option<f64>,
    ) -> Self {
        let (cmpl_tx, cmpl_rx) = channel::unbounded::<WorkCompletion>();
        let now = Instant::now();
        let (lat_pid, rps_pid) = Self::pid_controllers(&params);
        let trace = trace_path
            .as_deref()
            .map(|path| TraceReader::new(path, trace_launch_scale))
            .transpose()
            .expect("failed to load trace file");

        Self {
            work_iters_normal: Self::work_iters_normal(&params),
            sleep_normal: Self::sleep_normal(&params),
            concurrency_max: params.concurrency_max as f64,
            concurrency: (rd_util::nr_cpus() as f64 / 2.0)
                .max(1.0)
                .min(params.concurrency_max as f64),
            params,
            params_at: now,
            logger,
            cmd_rx,
            trace,
            trace_start_at,
            trace_next_at: now,
            trace_next_idx: 0,
            wq: WorkQueue::new(Duration::from_secs_f64(Self::WQ_IDLE_TIMEOUT)),
            cmpl_tx,
            cmpl_rx,
            lat_min: f64::MAX,
            lat_max: 0.0,
            ckms: CKMS::<f64>::new(Self::CKMS_ERROR),
            ckms_at: now,
            lat_pid,
            rps_pid,
            lat: Default::default(),
            nr_in_flight: 0,
            nr_done: 0,
            last_nr_done: 0,
            rps: 0.0,
        }
    }

    fn update_params(&mut self, new_params: Params) {
        self.params = new_params;
        self.work_iters_normal = Self::work_iters_normal(&self.params);
        self.sleep_normal = Self::sleep_normal(&self.params);
        let (lat_pid, rps_pid) = Self::pid_controllers(&self.params);
        self.lat_pid = lat_pid;
        self.rps_pid = rps_pid;
        self.concurrency_max = self.params.concurrency_max as f64;

        if let Some(logger) = self.logger.as_mut() {
            logger.set_padding(self.params.log_padding());
        }

        self.params_at = Instant::now();
    }

    fn launch_workers(&mut self) {
        let mut rng = SmallRng::from_entropy();

        while self.nr_in_flight < self.concurrency as u32 {
            let work_iters = self.work_iters_normal.sample(&mut rng).round() as u64;
            let sleep_dur = self.sleep_normal.sample(&mut rng);
            let cpu_ratio = self.params.cpu_ratio;
            let fake_cpu = self.params.fake_cpu_load;
            let cmpl_tx = self.cmpl_tx.clone();

            self.wq.queue(move || {
                let started_at = Instant::now();

                if fake_cpu {
                    // Just for compatibility with existing params.
                    sleep(Duration::from_secs_f64((work_iters as f64) * 1e-9));
                } else {
                    let fib = fib_burn(work_iters, cpu_ratio);
                    std::hint::black_box(fib);
                }

                if sleep_dur > 0.0 {
                    sleep(Duration::from_secs_f64(sleep_dur));
                }

                cmpl_tx.send(WorkCompletion { started_at }).unwrap();
            });

            self.nr_in_flight += 1;
        }
    }

    fn launch_workers_trace_driven(&mut self, launches: u32) {
        if launches == 0 {
            return;
        }

        let mut rng = SmallRng::from_entropy();

        for idx in 0..launches {
            let work_iters = self.work_iters_normal.sample(&mut rng).round() as u64;
            let start_delay = idx as f64 / launches as f64;
            let cpu_ratio = self.params.cpu_ratio;
            let fake_cpu = self.params.fake_cpu_load;
            let cmpl_tx = self.cmpl_tx.clone();

            self.wq.queue(move || {
                if start_delay > 0.0 {
                    sleep(Duration::from_secs_f64(start_delay));
                }

                let started_at = Instant::now();

                if fake_cpu {
                    sleep(Duration::from_secs_f64((work_iters as f64) * 1e-9));
                } else {
                    let fib = fib_burn(work_iters, cpu_ratio);
                    std::hint::black_box(fib);
                }

                cmpl_tx.send(WorkCompletion { started_at }).unwrap();
            });

            self.nr_in_flight += 1;
        }
    }

    fn process_trace_ticks(&mut self, now: Instant) {
        while now >= self.trace_next_at {
            let launches = {
                let trace = self.trace.as_ref().unwrap();
                if self.trace_next_idx >= trace.len() {
                    self.trace_next_idx = 0;
                }
                trace.launches_at(self.trace_next_idx)
            };
            self.concurrency = launches as f64;
            self.launch_workers_trace_driven(launches);
            self.trace_next_idx += 1;
            self.trace_next_at += Duration::from_secs(1);
        }
    }

    fn reset_lat_rps(&mut self, now: Instant) {
        self.lat_min = f64::MAX;
        self.lat_max = 0.0;
        self.ckms_at = now;
        self.ckms = CKMS::<f64>::new(Self::CKMS_ERROR);
        self.last_nr_done = self.nr_done;
    }

    fn refresh_lat_rps(&mut self, now: Instant) -> bool {
        let dur = now.duration_since(self.ckms_at);
        if dur.as_secs_f64() < self.params.control_period {
            return false;
        }

        if self.nr_done > self.last_nr_done {
            self.lat.min = self.lat_min;
            self.lat.p01 = self.ckms.query(0.01).unwrap().1;
            self.lat.p05 = self.ckms.query(0.05).unwrap().1;
            self.lat.p10 = self.ckms.query(0.10).unwrap().1;
            self.lat.p16 = self.ckms.query(0.16).unwrap().1;
            self.lat.p50 = self.ckms.query(0.50).unwrap().1;
            self.lat.p84 = self.ckms.query(0.84).unwrap().1;
            self.lat.p90 = self.ckms.query(0.90).unwrap().1;
            self.lat.p95 = self.ckms.query(0.95).unwrap().1;
            self.lat.p99 = self.ckms.query(0.99).unwrap().1;
            self.lat.p99_9 = self.ckms.query(0.999).unwrap().1;
            self.lat.p99_99 = self.ckms.query(0.9999).unwrap().1;
            self.lat.p99_999 = self.ckms.query(0.99999).unwrap().1;
            self.lat.max = self.lat_max;
            self.lat.ctl = self.ckms.query(self.params.lat_target_pct).unwrap().1;
        } else {
            self.lat = Default::default();
            if self.nr_in_flight > 0 {
                warn!(
                    "No completion in {} with {} requests in flight, con={:.1}/{:.1}",
                    rd_util::format_duration(self.params.control_period),
                    self.nr_in_flight,
                    self.concurrency,
                    self.concurrency_max
                );
                // Slam on the brakes.
                self.lat.ctl = self.params.lat_target * 10.0;
            }
        }

        self.rps = (self.nr_done - self.last_nr_done) as f64 / dur.as_secs_f64();
        self.reset_lat_rps(now);
        true
    }

    /// Two PID controllers work in conjunction to determine the concurrency
    /// level. The latency one caps the max concurrency to keep latency within
    /// the target. The RPS one tries to converge on the target RPS.
    fn update_control(&mut self) {
        let out = self
            .lat_pid
            .next_control_output(self.lat.ctl / self.params.lat_target.max(1e-9));
        let lat_adj = out.output;

        if lat_adj < 0.0 {
            self.concurrency_max = f64::min(self.concurrency_max, self.concurrency);
        }

        self.concurrency_max = (self.concurrency_max * (1.0 + lat_adj))
            .max(1.0)
            .min(self.params.concurrency_max as f64);

        let rps_target = (self.params.rps_target as f64).max(1.0);
        let rps_adj = self.rps_pid.next_control_output(self.rps / rps_target).output;
        self.concurrency = (self.concurrency * (1.0 + rps_adj)).max(1.0);

        if self.concurrency >= self.concurrency_max {
            self.concurrency = self.concurrency_max;
            self.rps_pid.reset_integral_term();
        } else {
            self.lat_pid.reset_integral_term();
        }

        if out.i.is_sign_negative() && (self.lat.ctl <= self.params.lat_target) {
            self.lat_pid.reset_integral_term();
        }

        debug!(
            "p50={:.1} p84={:.1} p90={:.1} p95={:.1} p99={:.1} ctl={:.1} rps={:.1} con={:.1}/{:.1}",
            self.lat.p50 * rd_util::TO_MSEC,
            self.lat.p84 * rd_util::TO_MSEC,
            self.lat.p90 * rd_util::TO_MSEC,
            self.lat.p95 * rd_util::TO_MSEC,
            self.lat.p99 * rd_util::TO_MSEC,
            self.lat.ctl * rd_util::TO_MSEC,
            self.rps,
            self.concurrency,
            self.concurrency_max,
        );
    }

    fn run(&mut self) {
        if self.trace.is_some() {
            if let Some(start_at) = self.trace_start_at {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_secs_f64();
                if start_at > now {
                    sleep(Duration::from_secs_f64(start_at - now));
                }

                let now = Instant::now();
                self.trace_next_at = now;
                self.params_at = now;
                self.reset_lat_rps(now);
            }
        }

        loop {
            let now = Instant::now();
            if self.trace.is_some() {
                self.process_trace_ticks(now);
            } else {
                self.launch_workers();
            }

            select! {
                recv(self.cmd_rx) -> cmd => {
                    match cmd {
                        Ok(DispatchCmd::SetParams(params)) => self.update_params(params),
                        Ok(DispatchCmd::GetStat(ch)) => {
                            ch.send(Stat {
                                lat: self.lat.clone(),
                                rps: self.rps,
                                concurrency: self.concurrency,
                                concurrency_max: self.concurrency_max,
                                file_addr_frac: 0.0,
                                anon_addr_frac: 0.0,
                                nr_in_flight: self.nr_in_flight,
                                nr_done: self.nr_done,
                                nr_workers: self.wq.nr_workers(),
                                nr_idle_workers: self.wq.nr_idle_workers(),
                                file_size: 0,
                                file_dist: vec![],
                                anon_size: 0,
                                anon_dist: vec![],
                            }).unwrap();
                        }
                        Ok(DispatchCmd::FillAnon) => {
                            // No-op for pure CPU workload.
                        }
                        Err(err) => {
                            debug!("DispatchThread: cmd_rx terminated ({:?})", err);
                            return;
                        }
                    }
                },
                recv(self.cmpl_rx) -> cmpl => {
                    match cmpl {
                        Ok(WorkCompletion { started_at }) => {
                            self.nr_in_flight -= 1;
                            self.nr_done += 1;
                            let dur = Instant::now().duration_since(started_at).as_secs_f64();
                            self.lat_min = self.lat_min.min(dur);
                            self.lat_max = self.lat_max.max(dur);
                            self.ckms.insert(dur);
                            if let Some(logger) = self.logger.as_mut() {
                                logger.log(&format!("fib {:.2}ms", dur * rd_util::TO_MSEC));
                            }
                        }
                        Err(err) => {
                            debug!("DispatchThread: cmpl_rx error ({:?})", err);
                            return;
                        }
                    }
                }
            }

            let now = Instant::now();
            if now.duration_since(self.params_at).as_secs() >= 1 {
                if self.refresh_lat_rps(now) && self.trace.is_none() {
                    self.update_control();
                }
            } else {
                self.reset_lat_rps(now);
            }
        }
    }
}

/// The main controlling entity users interact with. Creating a dispatch
/// spawns an associated dispatch thread which keeps scheduling workers
/// according to params.
pub struct Dispatch {
    cmd_tx: Option<Sender<DispatchCmd>>,
    dispatch_jh: Option<JoinHandle<()>>,
    stat_tx: Sender<Stat>,
    stat_rx: Receiver<Stat>,
}

impl Dispatch {
    pub fn new(
        _max_size: u64,
        _tf: TestFiles,
        params: &Params,
        _anon_comp: f64,
        logger: Option<Logger>,
        trace_path: Option<String>,
        trace_launch_scale: u32,
        trace_start_at: Option<f64>,
    ) -> Self {
        let params_copy = params.clone();
        let (cmd_tx, cmd_rx) = channel::unbounded();
        let dispatch_jh = Some(spawn(move || {
            let mut dt =
                DispatchThread::new(
                    params_copy,
                    logger,
                    cmd_rx,
                    trace_path,
                    trace_launch_scale,
                    trace_start_at,
                );
            dt.run();
        }));
        let (stat_tx, stat_rx) = channel::unbounded();

        Self {
            cmd_tx: Some(cmd_tx),
            dispatch_jh,
            stat_tx,
            stat_rx,
        }
    }

    pub fn set_params(&mut self, params: &Params) {
        self.cmd_tx
            .as_ref()
            .unwrap()
            .send(DispatchCmd::SetParams(params.clone()))
            .unwrap();
    }

    pub fn get_stat(&self) -> Stat {
        self.cmd_tx
            .as_ref()
            .unwrap()
            .send(DispatchCmd::GetStat(self.stat_tx.clone()))
            .unwrap();
        self.stat_rx.recv().unwrap()
    }

    pub fn fill_anon(&self) {
        self.cmd_tx
            .as_ref()
            .unwrap()
            .send(DispatchCmd::FillAnon)
            .unwrap();
    }
}

impl Drop for Dispatch {
    fn drop(&mut self) {
        drop(self.cmd_tx.take());
        debug!("Dispatch::drop: joining dispatch thread");
        let _ = self.dispatch_jh.take().unwrap().join();
        debug!("Dispatch::drop: done");
    }
}
