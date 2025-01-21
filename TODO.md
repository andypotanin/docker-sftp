# TODO List

## Done ✓
- [x] Fix Dockerfile build issues
  - [x] Remove unnecessary Google Cloud SDK
  - [x] Fix kubectl installation for different architectures
  - [x] Optimize base image and dependencies
  - [x] Fix permissions and user setup
- [x] Configure GitHub Actions
  - [x] Set up Docker image builds
  - [x] Push to Docker Hub
- [x] Document the project
  - [x] Create detailed blog post about the build process
  - [x] Share insights and lessons learned

## In Progress 🚧
- [ ] Cloud Run Integration
  - [ ] Configure proper authentication
  - [ ] Set up deployment workflow
  - [ ] Test auto-scaling

## To Do 📋
- [ ] Testing
  - [ ] Add integration tests
  - [ ] Add unit tests for Node.js components
  - [ ] Set up test automation in CI
- [ ] Security
  - [ ] Add security scanning in CI
  - [ ] Implement rate limiting
  - [ ] Add audit logging
- [ ] Features
  - [ ] Multi-cluster support
  - [ ] S3/GCS backend integration
  - [ ] Custom SFTP command handlers
  - [ ] Enhanced monitoring and metrics
- [ ] Documentation
  - [ ] API documentation
  - [ ] Configuration guide
  - [ ] Troubleshooting guide
  - [ ] Architecture diagrams

## Nice to Have 🎯
- [ ] Support for additional authentication providers
- [ ] Web UI for monitoring and management
- [ ] File preview capabilities
- [ ] Real-time notifications
- [ ] Performance metrics dashboard

## Known Issues 🐛
- [ ] Cloud Run deployment workflow needs proper secrets
- [ ] Need to verify ARM64 builds on actual hardware
- [ ] Documentation for enterprise deployment scenarios
