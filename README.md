# TestItemRunner2

Example:

```julia
using TestItemRunner2

run_tests("/users/foo/.julia/dev/InlineStrings")
```

## API

```julia
    run_tests(path; filter=nothing, verbose=false, max_workers::Int=Sys.CPU_THREADS, timeout=60*5, return_results=false, print_failed_results=true)
```

Runs test items. This will re-use client processes from a previous call to `run_tests`, but is guaranteed to use the latest code version (through a combination of static parsing and Revise).

Args:
- `path`: Filesystem path to a folder.
- `filter`: Not implemented right now.
- `verbose` Not implemented right now.
- `max_workers`: Max number of child processes per identified project.
- `timeout`: Timeout in seconds.
- `return_results`: Returns all test results as a vector, includes status, error messages and logs.
- `print_failed_results`: Print error messages for all failed tests when done running all tests.

```julia
    kill_test_processes()
```

Terminate all active client processes that are used to run test items.
