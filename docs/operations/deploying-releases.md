# Deploying Releases

## Overview

Releases are `.tar.gz` archives deployed through a fully automated pipeline: S3 upload triggers EventBridge, which invokes an SSM Automation document, which starts a CodeBuild job. CodeBuild mounts EFS, extracts the archive, links shared directories, and atomically switches the live symlink. No ECS task restart is required.

The pipeline is defined in:
- `eventbridge.tf` — S3 ObjectCreated rule
- `ssm_release.tf` — SSM Automation document
- `codebuild.tf` — CodeBuild project and IAM
- `buildspec.yml` — build steps

---

## 1. Package a Release

From your Magento root directory, create a tar archive. Use a timestamp in the filename so each release is uniquely named.

```bash
tar -czf release-$(date +%Y%m%d-%H%M%S).tar.gz -C /path/to/magento/root .
```

The archive should contain the full Magento installation: `app/`, `bin/`, `generated/`, `lib/`, `pub/`, `setup/`, `vendor/`, etc. Do not include `pub/media/` or `var/` — those are managed as shared directories on EFS and will be symlinked by the deployment script.

Typical archive size after excluding media: 200–600 MB depending on vendor packages.

---

## 2. Upload to the Releases S3 Bucket

The releases bucket name is `<project>-releases`. Get it from Terraform output if needed:

```bash
RELEASES_BUCKET=$(aws s3api list-buckets \
  --query "Buckets[?contains(Name,'releases')].Name" \
  --output text)

aws s3 cp release-20240101-120000.tar.gz s3://${RELEASES_BUCKET}/
```

Or directly by known name:

```bash
aws s3 cp release-20240101-120000.tar.gz s3://mystore-magento-releases/
```

Uploading the file is the only manual step required. Everything after this is automatic.

---

## 3. Automatic Pipeline

### EventBridge Rule

The `s3_release_update` EventBridge rule matches:

```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "bucket": { "name": ["mystore-magento-releases"] },
    "object": { "key": [{ "suffix": ".gz" }] }
  }
}
```

The rule fires within seconds of a successful S3 upload.

### SSM Automation Document

The rule target is the `mystore-magento-LatestReleaseDeployment` SSM Automation document. EventBridge passes the S3 object key via the `input_transformer` as `RELEASE_FILE`.

The SSM document performs two steps:
1. `StartCodeBuild` — calls `codebuild:StartBuild` with the project name and the `RELEASE_FILE` environment variable override.
2. `SendNotification` — publishes a message to the `devops` SNS topic with the build ID and release file name.

Failed EventBridge invocations are sent to an SQS dead-letter queue.

### CodeBuild Build Steps

CodeBuild runs in the VPC private subnets using an ARM64 Amazon Linux container (`aws/codebuild/amazonlinux-aarch64-standard:3.0`). EFS is mounted at `/mnt/efs` via the `file_system_locations` configuration.

The `buildspec.yml` executes the following:

**pre_build:**
```bash
RELEASE_NAME=$(basename $RELEASE_FILE .tar.gz)
RELEASE_TARGET="$RELEASES_DIR/$RELEASE_NAME"   # /mnt/efs/releases/<name>
mkdir -p "$RELEASE_TARGET"
mkdir -p "$SHARED_DIR"                           # /mnt/efs/shared
```

**build:**
```bash
# Download from S3
aws s3 cp "s3://$S3_RELEASE_BUCKET/$RELEASE_FILE" /tmp/release.tar.gz

# Extract
tar -xzf /tmp/release.tar.gz -C "$RELEASE_TARGET"

# Link shared directories (persisted across deployments)
ln -sfn "$SHARED_DIR/media" "$RELEASE_TARGET/pub/media"
ln -sfn "$SHARED_DIR/var"   "$RELEASE_TARGET/var"

# Atomic symlink switch
ln -sfn "$RELEASE_TARGET" "${PUBLIC_DIR}/current"
# PUBLIC_DIR=/mnt/efs/public
# This makes /mnt/efs/public/current point to the new release
```

**post_build:**
```bash
# Keep only the 3 most recent releases
ls -dt "$RELEASES_DIR"/*/ | tail -n +4 | xargs rm -rf || true
rm -f /tmp/release.tar.gz
```

---

## 4. Zero-Downtime Behaviour

ECS backend containers mount EFS with three access points:

| Access point | Container path | Mode |
|---|---|---|
| `public` | `/home/<brand>/public` | read-only |
| `shared` | `/home/<brand>/shared` | read-write |
| `releases` | `/home/<brand>/releases` | read-only |

The container `workingDirectory` is `/home/<brand>/public/current`. When CodeBuild updates the `/mnt/efs/public/current` symlink, the running containers resolve their working directory to the new release path on the next file access. No container restart or task replacement is needed.

PHP-FPM's opcode cache may serve cached bytecode from the previous release for a short period. To force immediate code execution from the new release, send a graceful reload signal to PHP-FPM inside the running containers:

```bash
# Using ECS Exec (requires enable_execute_command = true, already set in ecs.tf)
aws ecs execute-command \
  --cluster mystore-magento-backend-ecs-cluster \
  --task <task-id> \
  --container backend \
  --interactive \
  --command "kill -USR2 1"
```

---

## 5. Monitor Deployment

In the AWS Console:

1. Go to **CodeBuild** > **Build projects** > `mystore-magento-deploy-release`.
2. Click **Build history** to see the current and recent builds.
3. Click into a build to view real-time logs streamed to CloudWatch (`/aws/codebuild/mystore-magento-deploy-release`).

Via CLI:

```bash
# List recent builds
aws codebuild list-builds-for-project \
  --project-name mystore-magento-deploy-release \
  --sort-order DESCENDING

# Get build status
aws codebuild batch-get-builds \
  --ids mystore-magento-deploy-release:abc123 \
  --query 'builds[0].{Status:buildStatus,Start:startTime,End:endTime}'
```

An SNS notification is sent to the `devops` topic when the build is triggered, and a CodeStar Notifications rule sends status (succeeded, failed, stopped) to the same topic.

---

## 6. Rollback

### Automatic via Re-upload

The simplest rollback is to re-upload a previous release archive. The pipeline runs identically — CodeBuild extracts the archive, links shared directories, and switches the symlink.

```bash
# List releases in S3
aws s3 ls s3://mystore-magento-releases/

# Re-upload a previous version
aws s3 cp s3://mystore-magento-releases/release-20231215-090000.tar.gz \
          s3://mystore-magento-releases/release-20231215-090000.tar.gz \
  --metadata-directive REPLACE
```

The `--metadata-directive REPLACE` trick re-creates the object, which generates a new `Object Created` event and triggers the pipeline.

Alternatively, upload it under a new filename:

```bash
aws s3 cp s3://mystore-magento-releases/release-20231215-090000.tar.gz \
          s3://mystore-magento-releases/release-$(date +%Y%m%d-%H%M%S)-rollback.tar.gz
```

### Manual via SSM Session Manager

If you need to switch the symlink directly without waiting for CodeBuild:

```bash
# Start a session on the CodeBuild container is not possible, but you can
# exec into a running backend ECS task
aws ecs execute-command \
  --cluster mystore-magento-backend-ecs-cluster \
  --task <task-id> \
  --container backend \
  --interactive \
  --command "/bin/bash"

# Inside the container (path is /home/<brand>/releases/)
ln -sfn /home/mystore/releases/release-20231215-090000 /home/mystore/public/current
```

Note: the `shared` access point is read-write, but `public` and `releases` are read-only from the container. Use SSM Session Manager on the underlying EC2 instance to manipulate the EFS filesystem directly if needed:

```bash
aws ssm start-session --target <ec2-instance-id>
# EFS is not mounted on the EC2 host by default; mount it first
sudo mount -t efs <efs-id>:/ /mnt/efs
ln -sfn /mnt/efs/releases/release-20231215-090000 /mnt/efs/public/current
```

---

## 7. First-Time Setup After Deployment

After the first release is deployed, the Magento `setup:upgrade` and `setup:static-content:deploy` commands must be run inside the backend container to populate the database schema and compile static assets.

```bash
aws ecs execute-command \
  --cluster mystore-magento-backend-ecs-cluster \
  --task <task-id> \
  --container backend \
  --interactive \
  --command "/bin/bash"

# Inside the container
cd /home/mystore/public/current
php bin/magento setup:upgrade
php bin/magento setup:static-content:deploy -f
php bin/magento cache:flush
```

For ongoing deployments, include these commands in your CI/CD pipeline as a post-deploy step by running them via `aws ecs execute-command` from your pipeline.
