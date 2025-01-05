# zigdoc

A web server that generates and serves documentation from remote zig modules.

Inspired by [godoc](https://pkg.go.dev/golang.org/x/tools/cmd/godoc).

## Usage

### System Dependencies

The server currently assumes the following dependencies are installed on the system.
In the future the things requiring these can be moved to native zig code.

- `zig` in the `PATH` for building documentation.
- `git` in the `PATH` for cloning repositories.

### Running the server

```sh
zigdoc serve [flags]

USAGE:
  zigdoc [OPTIONS]

COMMANDS:
  serve
      --host <VALUE>           host to listen on
      --port <VALUE>           port to bind to
      --http-workers <VALUE>   number of http worker threads
      --data-dir <VALUE>       directory to store data

OPTIONS:
      --git-executable <VALUE>   path to the git executable (defaults to 'git')
      --zig-executable <VALUE>   path to the zig executable (defaults to 'zig')
      --zig-cache-dir <VALUE>    directory to store zig cache, defaults to the global zig cache directory
  -h, --help                     Show this help output.
```

This starts an HTTP server that listens on `0.0.0.0:8080` by default.
The server will serve documentation for any module that is requested.

You can then visit `http://localhost:8080/` (which is pretty barebones at the moment).
From there, much like `godoc`, append any repository path to the URL to have documentation generated and served for public modules in that repository.
For example, `http://localhost:8080/github.com/karlseguin/http.zig`

A specific version/branch can be requested by appending `@<version>` to the path.
This defaults to `latest` which will try to resolve either the newest tag or the latest commit on the default branch.

The list of supported hosts is currently hardcoded to `github.com` and `gitlab.com`.
This can be expanded as needed in the future, with potential support for vanity URLs.

## Building

```sh
# Or `zig build` for a debug build.
zig build -Doptimize=ReleaseFast
```

## License

MIT

## TODO

- [ ] Tests.
- [ ] Add a search bar to the UI.
- [ ] Expose a way to refresh the link to the latest version.
- [ ] Handle edge cases with documentation generation.
- [ ] Make things prettier.
- [ ] Whatever other people think of.
