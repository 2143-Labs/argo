{
  description = "Argo CD ops tools development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Secrets and encryption
            sops
            age

            # Argo CD and Kubernetes operations
            argocd
            kubectl
            kubernetes-helm
            kustomize

            # Common helpers for manifests and automation
            yq-go
            jq
            git
          ];

          shellHook = ''
            echo "Argo CD dev shell ready"
            echo "Tools: argocd, kubectl, helm, kustomize, sops, age-keygen, yq, jq"
          '';
        };
      });
}
