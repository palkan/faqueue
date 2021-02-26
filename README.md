# FaQueue

This repo contains code to experiment with different background jobs _fairness_ strategies.

## About

The problem of _fair_ background jobs processing usually occurs in multi-tenant applications using shared queues to process tasks (e.g., using Sidekiq). Imagine you have an named queue to process some tasks, say, outgoing E-mail or SMS notifications. This single queue serves all the tenants, big and small. Whenever a large tenant triggers a massive notifications delivery (`User.find_each { UserMailer.notify_smth.deliver_later }`) and enqueues thousands of jobs. Delivering notifications takes some time (hundreds of milliseconds or even seconds), the jobs processor would be _occupied_ by this tenant; others would experience noticable delays.

There are multiple ways to mitigate this problem and we research them in this repo.

Since this is a pure academical research, we avoid using any specific _executor_. Instead, we use Ruby 3 Ractors for concurrent jobs execution.
However, we assume that a background job executor has a fixed predefined set of queues (like Sidekiq); thus, we cannot use a queue-per-tenant approach, we need to introduce the fairness at the client-side.

## The method

We perform the following experiment for each strategy.

Given N numbers each representing the number of jobs to enqueue per tenant, we enqueue N background jobs (_bulk jobs_).
Each bulk jobs enqueues N[i] jobs.

Then we wait for all jobs to complete.

We measure the latency for each executed job and calculate the following statistical data:

- Mean and p90 latency per tenant.
- Mean and p90 latency of the first K jobs (_head_) per tenant, where K = min(N[i]).
- Standard deviation for the calculated means and percentiles.

The most important metrics is a standard deviation of the _heads_ means/percentiles. Why so? We're interested in minimizing delays caused by large tenants. In other words, we want jobs from all tenants to be executed at the same _speed_. On the other hand, it's OK for latency to grow if we enqueue thousands of jobs, but that should not affect those who enqueue dozens.

## Usage

Run a specific strategy emulation like this:

```sh
ruby baseline.rb -c 16 -n 300,20,500,200,1000,120
```

You will see a visualization of executed jobs (each color represents a particular tenant) and the final statistics information (see below).

To learn about available CLI options use `-h` switch:

```sh
$ ruby baseline.rb -h
Baseline: just a queue, totally unfair
    -n, --number=SCALES              The total number of jobs to enqueue per tenant (comma-separated)
    -c, --concurrency=CONCURRENCY    The concurrency factor (depends on implementation)
```

## Strategies

### Baseline

This is the default behavior: do not care about the fairness.

<p align="center">
  <img src="./assets/baseline.png" alt="Baseline profile" width="738">
</p>

### Shuffle shards

This strategy is described [here][sidekiq-shards].

With two shards:

<p align="center">
  <img src="./assets/shards_2.png" alt="Shuffle shards (2) profile" width="738">
</p>

With three shards:

<p align="center">
  <img src="./assets/shards_3.png" alt="Shuffle shards (3) profile" width="738">
</p>

With four shards (unfair):

<p align="center">
  <img src="./assets/shards_4_1.png" alt="Shuffle shards (4) profile" width="738">
</p>

With four shards (fair):

<p align="center">
  <img src="./assets/shards_4_2.png" alt="Shuffle shards (4) profile 2" width="738">
</p>

With four shards total and each batch using two shards:

<p align="center">
  <img src="./assets/shards_4x2.png" alt="Shuffle shards (4, 2 per batch) profile" width="738">
</p>

### Defined Shards

This approach assumes assigning a shard to each tenant. If we know how to distrbute tenants accross the shards so that
they do not block each other, that would be a good solution. However, that task by itself is not easy (and a totally different story).

<p align="center">
  <img src="./assets/defined_shards.png" alt="Predefined shards" width="738">
</p>

### Throttling + Rescheduling

This approach has been implemnted in one of the Evil Martians projects back in the days.

The idea is the following: we define a _cooldown period_ for each tenant, i.e., a period during which only a single job is allowed to be performed (actually, enqueued). Every time a job is executed, we store a _deadline_ (`now + cooldown`) in a distributed cache. If the next job arrives earlier than the deadline, we increase the deadline and re-schedules this job to be executed later.

<p align="center">
  <img src="./assets/throttle.png" alt="Throttling/Rescheduling profile" width="738">
</p>

See [the example implementation for Sidekiq](./examples/sidekiq_throttling_sheduler.rb).

### Interruptible iteration

This approach is inspired by the [job-iteration][] technique used in Shopify: instead of enqueuing atomic jobs for each batch, we perform
them synchrounously in a loop and _pause_ the iteration if we took more than the specified amount of time. "Pause" means re-enqueuing the current jobs with the cursor specified to indicate the starting point for the iteration.

<p align="center">
  <img src="./assets/iteration.png" alt="Iteration profile" width="738">
</p>

You can achieve a similar behaviour for Sidekiq via `job-iteration` by configaring an appropriate max wait time:

```ruby
JobIteration.max_job_runtime = 2.minutes
```

## Resources

- [The State of Background Jobs in 2019][kirs-post] by Kir Shatrov
- [Fairway][]

[kirs-post]: https://kirshatrov.com/2019/01/03/state-of-background-jobs/
[Fairway]: https://github.com/customerio/fairway
[sidekiq-shards]: https://www.mikeperham.com/2019/12/17/workload-isolation-with-queue-sharding/
[job-iteration]: https://github.com/Shopify/job-iteration
