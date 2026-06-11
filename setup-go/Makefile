# setup-go — build manually, commit artifacts deliberately (house rule:
# no auto-builds inside Dockerfiles/CI image steps).
BIN := bin/authsetup

.PHONY: build check test clean

build:
	mkdir -p bin
	go build -trimpath -ldflags="-s -w" -o $(BIN) ./cmd/authsetup

check:
	go vet ./...
	@test -z "$$(gofmt -l .)" || (echo "gofmt needed on:" && gofmt -l . && exit 1)
	go build ./...

test:
	go test ./...

clean:
	rm -rf bin
