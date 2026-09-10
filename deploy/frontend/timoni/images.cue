package main

// The cv_frontend container image. `repository` + `tag` are readable
// defaults; `digest` is the trust anchor and is overridden per publish from
// `deploy/frontend/current-image.txt` (the approved image, ADR 0009). The
// default digest below is a valid-format placeholder so `timoni mod vet`
// resolves — a real run always supplies the approved digest.
values: {
	image: {
		repository: *"ghcr.io/insuperposition/cv-frontend" | string
		tag:        *"main" | string
		digest:     *"sha256:0000000000000000000000000000000000000000000000000000000000000000" | string
	}
}
