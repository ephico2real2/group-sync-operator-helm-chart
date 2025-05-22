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
   helm lint .

   # Run a template test
   helm template . --debug

   # Test installation (if you have a test cluster)
   helm install group-sync . --dry-run --debug
   ```

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

