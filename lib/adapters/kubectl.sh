# shellcheck shell=bash
# lib/adapters/kubectl.sh — adapter for kubectl.
# Reference: https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/ (KUBECONFIG)
#
# Unlike the env-dir adapters, KUBECONFIG points at a FILE, not a directory.
# We keep that file at <profile_dir>/config and seed an empty one on init so
# the path always exists. Drop your cluster/context/credentials into it (or
# point your cloud provider's `get-credentials` command at it).

adapter_meta_name()        { echo "kubectl"; }
adapter_meta_cli_binary()  { echo "kubectl"; }
adapter_meta_env_var()     { echo "KUBECONFIG"; }
adapter_meta_strategy()    { echo "env-file"; }
adapter_meta_description() { echo "Kubernetes CLI (cluster/context/creds in a KUBECONFIG file)"; }

# Seed an empty kubeconfig file so KUBECONFIG always points at something.
adapter_init() {
  local profile_dir="$1"
  [ -f "$profile_dir/config" ] || touch "$profile_dir/config"
}

adapter_export_env() {
  local profile_dir="$1"
  printf 'KUBECONFIG=%s/config\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  KUBECONFIG="$profile_dir/config" exec kubectl "$@"
}
