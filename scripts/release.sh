#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
TAG_BODY="${2:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [tag_body]"
  echo "Example: $0 0.1.0"
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be in format X.Y.Z"
  exit 1
fi

if ! git diff-index --quiet HEAD --; then
  echo "Error: You have uncommitted changes. Commit or stash them before tagging a release."
  exit 1
fi

TAG="v$VERSION"
RELEASE_REPO="kenn-io/ghosthub"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: Tag $TAG already exists."
  exit 1
fi

TAG_MESSAGE="Release $VERSION"
if [[ -n "$TAG_BODY" ]]; then
  TAG_MESSAGE="$TAG_MESSAGE

$TAG_BODY"
fi

git tag -a "$TAG" -m "$TAG_MESSAGE"
git push origin "$TAG"

echo ""
echo "Pushed tag $TAG."
echo "GitHub Actions will build and publish the signed notarized DMG release to $RELEASE_REPO."
echo "Release URL: https://github.com/$RELEASE_REPO/releases/tag/$TAG"
