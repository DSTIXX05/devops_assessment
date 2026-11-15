terraform {
  # Pin the minor version. use_lockfile in the S3 backend requires >= 1.10; the
  # tested operator version is 1.17.1.
  required_version = "~> 1.17.0"
}
