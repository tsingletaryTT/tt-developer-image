# Local tt-toplike .deb packages

tt-toplike is **not** distributed via an apt PPA — it ships as `.deb` packages
that are installed manually (the same `dpkg -i` flow used on a real QB2).

`Dockerfile.qb2` step 7 `COPY`s this directory in and `dpkg -i`s any `.deb`
found here, so drop the built packages in before building the image:

```bash
# In the tt-toplike repo:
./build-deb.sh              # produces ../tt-toplike_*.deb and ../tt-toplike-app_*.deb

# Then copy them here:
cp ../tt-toplike_*.deb ../tt-toplike-app_*.deb path/to/tt-developer-image/docker/debs/
```

The `.deb` files themselves are git-ignored (built artifacts); only this README
and `.gitkeep` are tracked so the directory exists in the build context.

If this directory has no `.deb` when the image is built, step 7 falls back to
`cargo install tt-toplike` so the build still succeeds — but the `.deb` is the
intended, representative path.
