bundle: {
	apiVersion: "v1alpha1"
	name:       "homelab-k3s"
	instances: {
		"cert-manager": {
			module: url:     "oci://ghcr.io/stefanprodan/modules/cert-manager"
			module: version: "1.14.5"
			namespace: "cert-manager"
			values: {
				installCRDs: true
			}
		}
		"metrics-server": {
			module: url:     "oci://ghcr.io/stefanprodan/modules/metrics-server"
			module: version: "0.7.1"
			namespace: "kube-system"
			values: {
				args: ["--kubelet-insecure-tls"]
			}
		}
	}
}
