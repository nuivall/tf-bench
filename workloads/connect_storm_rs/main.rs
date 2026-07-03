//! Dedicated high-rate CQL connection-storm generator for ScyllaDB (Rust).
//!
//! This runs ON A SINGLE LOADER and produces a controlled, high-throughput
//! stream of SHORT-LIVED CQL sessions to drive up
//!
//!     rate(scylla_transport_cql_connections[...])   (new connections / second)
//!
//! Why Rust: the previous thread-per-session Python tool created one OS thread
//! and one full driver `Cluster` per session, so a single loader was limited by
//! the GIL to only a few hundred new connections/second. This tool uses the
//! async `scylla` driver on a Tokio worker pool, so each connect is a cheap
//! async task. Thousands of connects can be in flight concurrently, letting a
//! single loader sustain many thousands of new CQL sessions/second.
//!
//! Each storm event:
//!   1. builds a fresh `Session` to ONE randomly-chosen node (a new TCP + CQL
//!      STARTUP + AUTH handshake -> a genuine server-side CQL connection),
//!   2. is HELD for --hold seconds,
//!   3. is dropped (Session dtor tears the connection down).
//!
//! Sessions are launched at a steady target --rate. A semaphore bounds the
//! number of concurrently-open sessions so the loader cannot exhaust file
//! descriptors / memory when pushed to extreme rates. The aggregate cluster-wide
//! flood is (per-loader --rate x number of storm loaders).
//!
//! Contact points are SHUFFLED per session and only the first is used as the
//! single known node, so the control connection (and therefore the new-conn
//! load) spreads EVENLY across all nodes instead of piling onto the seed.
//!
//! Usage:
//!   connect_storm --duration 120s --rate 1000 --hold 2s \
//!       [--user cassandra] [--password cassandra] \
//!       [--max-inflight 40000] <scylla-ip-1> [scylla-ip-2 ...]

use std::num::NonZeroUsize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use clap::Parser;
use rand::seq::SliceRandom;
use rand::Rng;
use scylla::client::session_builder::SessionBuilder;
use scylla::client::PoolSize;
use tokio::sync::Semaphore;

#[derive(Parser, Debug)]
#[command(about = "Dedicated high-rate CQL connection-storm generator (Rust/scylla).")]
struct Args {
    /// Total storm length, e.g. 120s, 2m, 500ms, or a bare number of seconds.
    #[arg(long, default_value = "120s")]
    duration: String,

    /// New sessions opened per second (steepness knob). Aggregate flood is
    /// this value x number of storm loaders.
    #[arg(long, default_value_t = 1000.0, env = "STORM_RATE")]
    rate: f64,

    /// How long each session is held open before being closed.
    #[arg(long, default_value = "2s", env = "STORM_HOLD")]
    hold: String,

    /// Maximum number of concurrently-open sessions (fd / memory safety valve).
    /// At steady state ~ rate*hold sessions are open; this caps bursts above that.
    #[arg(long, default_value_t = 40000, env = "STORM_MAX_INFLIGHT")]
    max_inflight: usize,

    /// CQL username for PasswordAuthenticator.
    #[arg(long, default_value = "cassandra", env = "SCYLLA_USER")]
    user: String,

    /// CQL password for PasswordAuthenticator.
    #[arg(long, default_value = "cassandra", env = "SCYLLA_PASSWORD")]
    password: String,

    /// CQL port.
    #[arg(long, default_value_t = 9042)]
    port: u16,

    /// ScyllaDB node IP(s).
    #[arg(required = true)]
    nodes: Vec<String>,
}

/// Parse a duration like "120s", "2m", "500ms", "1h", or a bare number of seconds.
fn parse_duration(text: &str, default_secs: f64) -> Duration {
    let t = text.trim().to_lowercase();
    let secs = if let Some(v) = t.strip_suffix("ms") {
        v.parse::<f64>().map(|x| x / 1000.0)
    } else if let Some(v) = t.strip_suffix('s') {
        v.parse::<f64>()
    } else if let Some(v) = t.strip_suffix('m') {
        v.parse::<f64>().map(|x| x * 60.0)
    } else if let Some(v) = t.strip_suffix('h') {
        v.parse::<f64>().map(|x| x * 3600.0)
    } else {
        t.parse::<f64>()
    }
    .unwrap_or(default_secs);
    Duration::from_secs_f64(secs.max(0.0))
}

/// Open one CQL session to a single randomly-chosen node, hold it, then drop it.
async fn open_hold_close(
    nodes: Arc<Vec<String>>,
    port: u16,
    user: String,
    password: String,
    hold: Duration,
    opened: Arc<AtomicU64>,
    failed: Arc<AtomicU64>,
    closed: Arc<AtomicU64>,
) {
    // Pick one node at random so control connections fan out evenly across the
    // cluster rather than always hitting the first (seed) contact.
    let node = {
        let mut rng = rand::thread_rng();
        nodes.choose(&mut rng).cloned().unwrap_or_default()
    };
    let addr = format!("{node}:{port}");

    let build = SessionBuilder::new()
        .known_node(addr)
        .user(&user, &password)
        .connection_timeout(Duration::from_secs(10))
        // One connection per host so each session maps to a minimal, predictable
        // number of new server-side connections (rather than a full shard-aware
        // pool), keeping --rate ~ new-connections/second.
        .pool_size(PoolSize::PerHost(NonZeroUsize::new(1).unwrap()))
        .build()
        .await;

    match build {
        Ok(session) => {
            opened.fetch_add(1, Ordering::Relaxed);
            // Hold ONLY successful sessions open for the configured duration, then
            // let them drop at end of scope (Session dtor closes the connections).
            tokio::time::sleep(hold).await;
            drop(session);
            closed.fetch_add(1, Ordering::Relaxed);
        }
        Err(_) => {
            // A failed connect returns IMMEDIATELY — no `hold` sleep — so its
            // in-flight permit is released right away and the pacer never stalls
            // waiting on failures. The hold is a property of a live session only.
            failed.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let args = Args::parse();

    let duration = parse_duration(&args.duration, 120.0);
    let hold = parse_duration(&args.hold, 2.0);
    let rate = args.rate.max(0.001);
    let interval = Duration::from_secs_f64(1.0 / rate);

    let host = std::env::var("HOSTNAME").unwrap_or_else(|_| "loader".to_string());

    println!("=========================================================================");
    println!(" CONNECTION STORM (rust/scylla) starting on {host}");
    println!("   target nodes      : {}", args.nodes.join(" "));
    println!(
        "   duration          : {}  ({:.0}s)",
        args.duration,
        duration.as_secs_f64()
    );
    println!("   launch rate       : {rate} new sessions/s  (steepness)");
    println!("   hold per session  : {}  ({:.3}s)", args.hold, hold.as_secs_f64());
    println!("   max in-flight     : {}", args.max_inflight);
    println!("   auth user         : {}", args.user);
    println!("   balancing         : per-session random node (even fan-out)");
    println!("=========================================================================");

    let nodes = Arc::new(args.nodes.clone());
    let opened = Arc::new(AtomicU64::new(0));
    let failed = Arc::new(AtomicU64::new(0));
    let closed = Arc::new(AtomicU64::new(0));
    let launched = Arc::new(AtomicU64::new(0));
    // Bound concurrently-open sessions so extreme rates can't exhaust fds/memory.
    let sem = Arc::new(Semaphore::new(args.max_inflight));

    let deadline = Instant::now() + duration;
    let mut next_launch = Instant::now();

    // Pacer loop: spawn a new connect task every `interval` until the deadline.
    //
    // The launch cadence is driven purely by wall-clock time (`next_launch`) and
    // is DECOUPLED from how long individual sessions live. This is deliberate:
    //   * `--hold` governs only how long a SUCCESSFULLY opened session is kept
    //     before being dropped; it must NOT throttle new-connection launches.
    //   * a FAILED connect returns immediately (no hold) and frees its in-flight
    //     permit right away, so a wave of failures cannot stall the pacer.
    // Together this keeps a smooth, continuous stream of new-connection attempts
    // (no sawtooth spikes/gaps) regardless of per-connect success or latency.
    //
    // Sub-millisecond random jitter is added to every interval so launches don't
    // align into periodic bursts (which show up as spikes on the monitoring
    // scrape) — connects are smeared evenly within each tick instead.
    while Instant::now() < deadline {
        let now = Instant::now();
        if now < next_launch {
            tokio::time::sleep((next_launch - now).min(Duration::from_millis(2))).await;
            continue;
        }

        // Acquire an in-flight permit. This ceiling only exists as an fd/memory
        // safety valve. If we're momentarily at the cap, DON'T drop this launch
        // (that would create a gap and then a catch-up burst); instead yield
        // briefly and retry so the launch still happens and cadence is preserved.
        let permit = match Arc::clone(&sem).try_acquire_owned() {
            Ok(p) => p,
            Err(_) => {
                tokio::time::sleep(Duration::from_micros(200)).await;
                continue;
            }
        };

        let nodes = Arc::clone(&nodes);
        let (o, f, c) = (Arc::clone(&opened), Arc::clone(&failed), Arc::clone(&closed));
        let (user, password) = (args.user.clone(), args.password.clone());
        let port = args.port;
        launched.fetch_add(1, Ordering::Relaxed);

        tokio::spawn(async move {
            let _permit = permit; // released when the task (session hold) ends
            open_hold_close(nodes, port, user, password, hold, o, f, c).await;
        });

        // Advance to the next launch slot and add sub-ms jitter (0..1000 µs) so
        // successive connects don't fire in lockstep, smoothing the stream.
        let jitter_us = rand::thread_rng().gen_range(0..1000);
        next_launch += interval + Duration::from_micros(jitter_us);
    }

    // Drain: wait for in-flight sessions to finish their hold + close. Acquiring
    // all permits means every outstanding session has completed.
    println!("[{host}] storm launch window closed; draining in-flight sessions...");
    let _ = sem.acquire_many(args.max_inflight as u32).await;

    println!("=========================================================================");
    println!(
        " CONNECTION STORM finished on {host}: launched={} opened={} closed={} failed={}",
        launched.load(Ordering::Relaxed),
        opened.load(Ordering::Relaxed),
        closed.load(Ordering::Relaxed),
        failed.load(Ordering::Relaxed)
    );
    println!("=========================================================================");
}
