# Commit each pinned KiroCrew tag must resolve to. Tags can be moved or
# re-created upstream; the builder (kirocrew-source-build.nix) refuses to build
# a tag whose commit differs from the one recorded here.
#
# Bump together with ./kirocrew-source-tag.nix. The commit is the peeled one
# (annotated tags have their own object id); get it with:
#   git ls-remote https://github.com/kirodotdev/KiroCrew.git 'refs/tags/<tag>^{}'
{
  "v0.7.2" = "c67c5060a82faf6e5e1bc06077122c473d4ca456";
}
