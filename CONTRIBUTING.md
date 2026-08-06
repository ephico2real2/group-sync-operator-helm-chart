# Contributing to Group Sync Operator Helm Chart

We love your input! We want to make contributing to this Helm chart as easy and transparent as possible, whether it's:

- Reporting a bug
- Discussing the current state of the configuration
- Submitting a fix
- Proposing new features
- Becoming a maintainer

## Development Process

We use GitHub to host code, to track issues and feature requests, as well as accept pull requests.

1. Fork the repo and create your branch from `main`.
2. If you've added code that should be tested, add tests.
3. If you've changed APIs, update the documentation.
4. Ensure the test suite passes.
5. Make sure your code lints.
6. Issue that pull request!

## Local Development

To develop the chart locally:

1. Clone the repository:

   ```bash
   git clone https://github.com/ephico2real2/group-sync-operator-helm-chart.git
   cd group-sync-operator-helm-chart
   ```

2. Make your changes to the chart.

3. Test your changes:

   ```bash
   # Lint the chart
   helm lint charts/group-sync-operator-helm -f charts/group-sync-operator-helm/crc-values.yaml

   # Render it. A values file is required: groupSync.url is empty in the base values, and
   # deriving it from the OAuth CR needs a live cluster, which helm template does not have.
   helm template charts/group-sync-operator-helm -f charts/group-sync-operator-helm/crc-values.yaml --debug

   # Test installation (if you have a test cluster)
   helm install group-sync charts/group-sync-operator-helm -f charts/group-sync-operator-helm/crc-values.yaml --dry-run --debug
   ```

4. Run the actual CI, locally.

   The commands above are a small fraction of what CI asserts. `.github/workflows/ci.yaml` renders 19
   value combinations, checks that the README's parameter tables still match `values.yaml`, and
   verifies the test scripts ship non-empty — a class of bug the commands above cannot see. All of it
   runs on your machine:

   ```bash
   ./ci/act-local.sh                  # every job, exits non-zero if any fails
   ./ci/act-local.sh docs chart       # just those jobs
   ./ci/act-local.sh --list           # what jobs exist
   ```

   Needs [act](https://nektosact.com/installation/) (`brew install act`) and a container runtime —
   docker or podman, whichever is running; the script finds it and builds into the same daemon `act`
   reads. A full pass takes two and a half to three minutes. The first run also builds a runner image
   on top of a 1.7 GB base, so budget for that pull once.

   It runs the `pull_request` event, because `version-bump` is gated on it and `act push` skips that job
   without saying so. That job diffs the chart against the merge-base with the default branch; override
   the base with `ACT_BASE_REF=<branch-or-sha>`.

   Two ways it is still weaker than the GitHub run, both of which the script tells you about:
   `version-bump` compares **commits**, so a chart edit you have not committed is invisible to it; and
   on the default branch the merge-base is `HEAD`, so the diff is empty and the job passes having
   compared nothing.

## Release Process

The chart is automatically released when changes are merged to the main branch. The GitHub Action workflow will:

1. Create a new chart version
2. Package the chart
3. Upload the packaged chart
4. Update the Helm repository index

To release a new version:

1. Update the `version` field in `Chart.yaml`
2. Commit your changes
3. Create a pull request
4. Once merged, the GitHub Action will automatically release the new version

## Pull Request Process

1. Update the README.md with details of changes to the interface
2. Update the Chart.yaml version following semantic versioning
3. The PR will be merged once you have the sign-off of the maintainer

## Any Questions?

Feel free to open an issue with your question or contact the maintainers directly.
