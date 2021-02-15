# FaQueue

This repo contains code to experiment with different background jobs _fairness_ strategies.

## About

The problem of _fair_ background jobs processing usually occurs in multi-tenant applications using shared queues to process tasks (e.g., using Sidekiq). Imagine you have an named queue to process some tasks, say, outgoing E-mail or SMS notifications. This single queue serves all the tenants, big and small. Whenever a large tenant triggers a massive notifications delivery (`User.find_each { UserMailer.notify_smth.deliver_later }`) and enqueues thousands of jobs. Delivering notifications takes some time (hundreds of milliseconds or even seconds), the jobs processor would be _occupied_ by this tenant; others would experience noticable delays.

There are multiple ways to mitigate this problem and we research them in this repo.

Since this is a pure academical research, we avoid using any specific _executor_. Instead, we use Ruby 3 Ractors for concurrent jobs execution.

## The method

TBD

## Strategies

TBD

## Usage

Run a specific strategy emulation like this:

```sh
ruby baseline.rb -c 16 -n 300,20,500,200,1000,120
```

You will see a visualization of executed jobs (each color represents a particular tenant) and the final statistics information.

To learn about available CLI options use `-h` switch:

```sh
$ ruby baseline.rb -h
Baseline: just a queue, totally unfair
    -n, --number=SCALES              The total number of jobs to enqueue per tenant (comma-separated)
    -c, --concurrency=CONCURRENCY    The concurrency factor (depends on implementation)
```

## Resources

- [The State of Background Jobs in 2019][kirs-post] by Kir Shatrov
- [Fairway][]

[kirs-post]: https://kirshatrov.com/2019/01/03/state-of-background-jobs/
[Fairway]: https://github.com/customerio/fairway
