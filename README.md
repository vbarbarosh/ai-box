<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/cover-dark.png">
  <img alt="ai-box" src="img/cover.png">
</picture>

# ai-box

An ephemeral environment for coding agents.

## Quick start

```bash
bin/configure      # install what the host is missing
bin/build          # build the image and fill data/extras
bin/run claude     # an agent in a box on the current directory
```

## Documentation

Full documentation: **[docs/README.md](docs/README.md)**

* [What the host needs](docs/README.md#what-the-host-needs) — packages, devices, subordinate ids
* [Usage](docs/README.md#usage) — the verbs, what a box gets, commit and push, limits
* [Running containers inside it](docs/README.md#running-containers-inside-it) — how nesting works and why

## License

[MIT](LICENSE)
