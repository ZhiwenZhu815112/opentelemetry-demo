# Contributing to OpenTelemetry Demo Webstore

Welcome to the ENPM818R Group Prject: Microservices on EKS (OpenTelemetry).
This project builds on the capabilities provided in the open-source OpenTelemetry Demo repo available via [github](https://github.com/open-telemetry/opentelemetry-demo) which we have broken into seperate microservices for the purpose of this project.


Meetings are held on Monday over Google Meets weekly at 9:00pm ET. The schedule may change based on teamates' avaiability.


## Ways to contribute
- Document actions
- Submit code changes via pull requests
- Generate branches to address specific tasks/sections

### Collaboorate with team 

In order to efficiently collaborate on this project, effective communication will be essential to the overall success of this project. Additionally, UMD emails will be used as the primary contact for each member.

## Setting Up Your Development Environment


### Prerequisites

Ensure you have the following installed:

- [Git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)
- [Make](https://www.gnu.org/software/make/)
- [Docker](https://www.docker.com/get-started/)
- [Docker Compose](https://docs.docker.com/compose/install/#install-compose) v2.0.0+


##Getting Started

### Clone the forked Repository

```sh
git clone https://github.com/ZhiwenZhu815112/opentelemetry-demo.git
cd opentelemetry-demo/
```

### Run the Demo

Follow instructions provided in README.md file.

### Verify the Webstore & Telemetry

Once the images are built and containers are started, visit:

- **Webstore**: [http://localhost:8080/](http://localhost:8080/)
- **Jaeger**: [http://localhost:8080/jaeger/ui/](http://localhost:8080/jaeger/ui/)
- **Grafana**: [http://localhost:8080/grafana/](http://localhost:8080/grafana/)
- **Feature Flags UI**: [http://localhost:8080/feature/](http://localhost:8080/feature/)
- **Load Generator UI**: [http://localhost:8080/loadgen/](http://localhost:8080/loadgen/)

## Troubleshooting Common Issues

### Docker Not Running

**Error:** `Error response from daemon: Docker daemon is not running.`

**Solution:**

- **Windows/macOS**: Open Docker Desktop and ensure it's running.
- **Linux**: Check Docker status:

```sh
systemctl status docker
```

If inactive, start it:

```sh
sudo systemctl start docker
  ```

### Gradle Issues (Windows)

If you encounter Gradle issues, run:

```sh
cd src/ad/
./gradlew installDist
./gradlew wrapper --gradle-version 7.4.2
```

### Docker build cache issues

While developing, you may encounter issues with Docker build cache. To clear the
cache:

```sh
docker system prune -a
```

Warning: This removes all unused Docker data, including images, containers,
volumes, and networks. Use with caution.

### Debugging Tips

- Use `docker ps` to check running containers.
- View logs for services:

```sh
docker logs <container_id>
```

- Restart containers if needed:

```sh
docker-compose restart
```

## Issues

- Search existing issues before opening a new one.
- When creating an issue, clearly describe what:
  - The problem or request 
  - Steps to reproduce (for bugs)
  - Expected vs actual behavior
  - Relevant logs, screenshots, or configuration snippets


### How to Send Pull Requests

Open a pull request against the `docker-Microservices`  branch.
- In the PR description, include:
  - Summary of the change
  - Related issue numbers (for example, “Closes #123”)
  - Testing performed
  - Any additional details
- Ensure:
  - All checks pass
  - Code follows the project’s style and conventions

```

Check out a new branch, make modifications and push the branch to your fork:

```sh
$ git checkout -b feature
# change files
# Test your changes locally.
$ docker compose up -d --build
# Go to Webstore, Jaeger or docker container logs etc. as appropriate to make sure your changes are working correctly.
$ git add my/changed/files
$ git commit -m "short description of the change"
$ git push fork feature
```

Open a pull request against the forked `opentelemetry-demo` repo.

### How to Receive Comments

Feedback will be provided over Google teams chat.

### How we will Get PRs Merged

Approver will review pull requests and if all tests and checks pass, will approve merge request.

