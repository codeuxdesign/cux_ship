# Changelog

## 0.1.0

First release. A Dart port of [`git-buildnumber.sh`][gbn] v1.3, and a drop-in
replacement for it — same refs, same commands, same stdout.

[gbn]: https://github.com/hpoul/git-buildnumber

**0.x deliberately.** The compatibility surface here is not this package's to
define: it is whatever the shell script does, including the parts nobody would
design on purpose — `find-commit` printing a whole `git log` block, `get`
exiting 0 with empty output on an unnumbered commit. That surface is pinned by a
vendored copy of the shell project's own acceptance suite, which passes, but a
1.0 would be a promise about an interface this package does not own.

### What the port is for

The argument lists handed to `git` are pure functions returning `List<String>`,
and the tests read them directly. That is the whole case for rewriting a working
tool: the worst defect in its history was a `+` on the push refspec beside
`--force-with-lease`, which git accepts silently and which no run reveals until
two machines allocate at the same instant. It is now a unit test that fails in
milliseconds.

The counter arithmetic and the retry decisions are pure functions for the same
reason; sequencing and I/O are confined to one file.

### Compatibility

Chain entries written before v1.3 — which every existing repository has — are
read without complaint, the counter blob keeps the trailing newline that is part
of its hash, and the two implementations may be used against one repository in
either order.

**One deliberate divergence:** a failed `git fetch` is fatal in every command.
The shell calls fetch inside `&&` lists, where bash suspends `errexit`, so a
failure there is silently continued past and `fetch` can exit 0 having fetched
nothing. Stricter than the original and invisible to the shared suite, so it is
recorded rather than left to be discovered.
