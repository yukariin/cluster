# Review mechanics

Commands describe inspection, not merge or deployment authorization. Verify
installed tools and current endpoints.

## Forgejo PRs

The public read API has historically allowed anonymous access:

- `GET https://git.mistelinn.org/api/v1/repos/yukarin/cluster/pulls/N`
- `GET https://git.mistelinn.org/api/v1/repos/yukarin/cluster/pulls/N.diff`
- `GET https://git.mistelinn.org/api/v1/repos/yukarin/cluster/issues/N/comments`

Replace `N` with the PR number. Use the current PR metadata for the base and head;
do not assume the local `main` branch or sticky Flate comment is current.

To inspect the head without replacing the user's checkout:

```sh
git fetch origin main refs/pull/N/head:refs/remotes/origin/pr-N
git diff origin/main...origin/pr-N
git merge-tree --write-tree origin/main origin/pr-N
```

`merge-tree` writes Git objects but does not merge into the working tree. For an
exact reproduction, retain the fetched base/head SHAs; branches can move later.
Prefer a disposable checkout when rendering or testing another branch.

## Images and upstream sources

For a multi-platform image, the digest Renovate pins may be the image index;
compare the raw manifest rather than a platform-specific config digest:

```sh
skopeo inspect --raw docker://IMAGE:TAG | shasum -a 256
skopeo inspect --override-os linux --override-arch amd64 --config docker://IMAGE:TAG
```

Replace `IMAGE:TAG` first. The platform override avoids inspecting darwin/arm64
on this Mac. Verify the workload's actual platform before choosing an override.

Read upstream files at both exact tags, especially entrypoints, migration code,
configuration parsing, and auth flows used here. Quote URLs containing `?` in
zsh. Use an available GitHub connector, `gh api`, or direct upstream source URLs.

## Deployment path

The repository's `origin` is Forgejo; the FluxInstance sync configuration pulls
`https://github.com/yukariin/cluster`. Compare both remote HEADs and the live
GitRepository artifact revision when a merged change is missing from the cluster.
Mirror lag is a possible cause; read-only investigation does not authorize
catch-up pushes or forced deployment.
