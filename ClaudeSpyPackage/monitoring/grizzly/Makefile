.PHONY: apply pull diff lint check-env

GRR := grr -d .

check-env:
	@: $${GRAFANA_URL:?GRAFANA_URL must be set}
	@: $${GRAFANA_TOKEN:?GRAFANA_TOKEN must be set}
	@: $${DISCORD_WEBHOOK_URL:?DISCORD_WEBHOOK_URL must be set}

apply: check-env
	$(GRR) apply .

diff: check-env
	$(GRR) diff .

pull: check-env
	$(GRR) pull . -d ./pulled

lint:
	$(GRR) lint
