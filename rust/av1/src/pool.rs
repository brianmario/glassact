//! The encoder's worker threads: one pool for every parallel loop (tiles, bands of rows, the copy
//! finder's rows), started once and parked between loops. Starting threads for each loop cost
//! 30-150 µs a loop (8-24 threads, measured on an M-series Mac), against about 10 µs to wake parked
//! ones; with tasks of 20-500 µs, GCD's `dispatch_apply` was slower still (it takes on workers
//! gradually). Loops from several threads at once (the closed loop, the copy finder, the writer)
//! share the pool: each caller works on its own loop, and idle workers help whichever has tasks
//! left.

use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};

/// A loop's tasks: `f(0..n)`, claimed in order through `next`.
struct Job {
    /// the caller's closure, its lifetime erased (see [`run`])
    f: *const (dyn Fn(usize) + Sync + 'static),
    n: usize,
    next: AtomicUsize,
    /// tasks not finished yet
    left: AtomicUsize,
    panicked: AtomicBool,
    payload: Mutex<Option<Box<dyn std::any::Any + Send>>>,
}

// SAFETY: `f` points at a `Sync` closure, which `run` keeps alive until no thread can call it.
unsafe impl Send for Job {}
// SAFETY: as for Send; the rest is atomics and a mutex.
unsafe impl Sync for Job {}

impl Job {
    /// Runs tasks until none is left to claim.
    fn work(&self, pool: &Pool) {
        loop {
            let k = self.next.fetch_add(1, Ordering::Relaxed);
            if k >= self.n {
                return;
            }
            // SAFETY: task k is claimed and not finished, so `run` hasn't returned: its closure is alive.
            let f = unsafe { &*self.f };
            if let Err(p) = catch_unwind(AssertUnwindSafe(|| f(k))) {
                self.panicked.store(true, Ordering::Relaxed);
                self.payload.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert(p);
            }
            if self.left.fetch_sub(1, Ordering::AcqRel) == 1 {
                // the last task: its caller may be waiting
                drop(pool.done.lock().unwrap_or_else(|e| e.into_inner()));
                pool.finished.notify_all();
            }
        }
    }
}

struct Pool {
    /// loops with tasks left to claim (exhausted ones are dropped as they're seen)
    jobs: Mutex<Vec<Arc<Job>>>,
    wake: Condvar,
    done: Mutex<()>,
    finished: Condvar,
    workers: usize,
}

impl Pool {
    fn get() -> &'static Pool {
        static POOL: OnceLock<&'static Pool> = OnceLock::new();
        POOL.get_or_init(|| {
            let workers = std::thread::available_parallelism()
                .map_or(1, |n| n.get())
                .saturating_sub(1);
            let pool: &'static Pool = Box::leak(Box::new(Pool {
                jobs: Mutex::new(Vec::new()),
                wake: Condvar::new(),
                done: Mutex::new(()),
                finished: Condvar::new(),
                workers,
            }));
            for i in 0..workers {
                let started = std::thread::Builder::new()
                    .name(format!("av1 worker {i}"))
                    .spawn(move || pool.worker());
                if started.is_err() {
                    break;
                }
            }
            pool
        })
    }

    fn worker(&self) {
        let mut jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            jobs.retain(|j| j.next.load(Ordering::Relaxed) < j.n);
            let Some(job) = jobs.first().cloned() else {
                jobs = self.wake.wait(jobs).unwrap_or_else(|e| e.into_inner());
                continue;
            };
            drop(jobs);
            job.work(self);
            jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        }
    }
}

/// Calls `f(i)` for every `i` in `0..n`, on this thread and the pool's, and returns when every call
/// has: a scope, so `f` may borrow from the caller. A panic in any call is resumed here once all
/// have returned.
pub(crate) fn run<F: Fn(usize) + Sync>(n: usize, f: F) {
    if n == 0 {
        return;
    }
    let pool = Pool::get();
    if n == 1 || pool.workers == 0 {
        (0..n).for_each(f);
        return;
    }
    let f: &(dyn Fn(usize) + Sync) = &f;
    // SAFETY: only the lifetime changes. Every call of `f` happens on a claimed task, and this
    // function returns (or unwinds) only after `left` reaches 0, when every claimed task has
    // finished and no unclaimed one is left (`next` >= n, so a late worker calls nothing).
    let f: *const (dyn Fn(usize) + Sync + 'static) =
        unsafe { core::mem::transmute(f as *const (dyn Fn(usize) + Sync)) };
    let job = Arc::new(Job {
        f,
        n,
        next: AtomicUsize::new(0),
        left: AtomicUsize::new(n),
        panicked: AtomicBool::new(false),
        payload: Mutex::new(None),
    });
    pool.jobs.lock().unwrap_or_else(|e| e.into_inner()).push(job.clone());
    for _ in 0..(n - 1).min(pool.workers) {
        pool.wake.notify_one();
    }
    job.work(pool);
    let mut done = pool.done.lock().unwrap_or_else(|e| e.into_inner());
    while job.left.load(Ordering::Acquire) != 0 {
        done = pool.finished.wait(done).unwrap_or_else(|e| e.into_inner());
    }
    drop(done);
    if job.panicked.load(Ordering::Relaxed)
        && let Some(p) = job.payload.lock().unwrap_or_else(|e| e.into_inner()).take()
    {
        resume_unwind(p);
    }
}

/// [`run`] over `items`, each call with one of them.
pub(crate) fn each<T: Send>(items: &mut [T], f: impl Fn(&mut T) + Sync) {
    let cells: Vec<Mutex<&mut T>> = items.iter_mut().map(Mutex::new).collect();
    run(cells.len(), |k| {
        f(&mut cells[k].lock().unwrap_or_else(|e| e.into_inner()))
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_task_runs_once_from_many_callers() {
        let callers: Vec<_> = (0..4)
            .map(|c| {
                std::thread::spawn(move || {
                    for round in 0..200 {
                        let n = 1 + (round * 7 + c) % 40;
                        let hits: Vec<AtomicUsize> = (0..n).map(|_| AtomicUsize::new(0)).collect();
                        run(n, |i| {
                            // nested loops too
                            if i % 9 == 0 {
                                run(3, |_| {});
                            }
                            hits[i].fetch_add(1, Ordering::Relaxed);
                        });
                        assert!(hits.iter().all(|h| h.load(Ordering::Relaxed) == 1));
                    }
                })
            })
            .collect();
        for c in callers {
            c.join().unwrap();
        }
    }

    #[test]
    fn a_panic_reaches_the_caller_after_every_task() {
        let finished = AtomicUsize::new(0);
        let r = catch_unwind(AssertUnwindSafe(|| {
            run(16, |i| {
                std::thread::sleep(std::time::Duration::from_millis(1));
                finished.fetch_add(1, Ordering::Relaxed);
                assert!(i != 5, "task 5");
            })
        }));
        assert!(r.is_err());
        assert_eq!(finished.load(Ordering::Relaxed), 16);
        // the pool still works
        let sum = AtomicUsize::new(0);
        run(10, |i| {
            sum.fetch_add(i, Ordering::Relaxed);
        });
        assert_eq!(sum.load(Ordering::Relaxed), 45);
    }

    #[test]
    fn each_gives_every_item() {
        let mut v: Vec<u32> = (0..100).collect();
        each(&mut v, |x| *x *= 2);
        assert!(v.iter().enumerate().all(|(i, &x)| x == 2 * i as u32));
    }
}
