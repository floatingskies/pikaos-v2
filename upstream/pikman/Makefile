all:
	true

# Hermetic, offline-capable build. Dependencies are vendored in-tree
# (vendor/), so GOPROXY is forced off: no network access needed and the
# build can never silently pull a different upstream revision.
install:
	mkdir -p $(DESTDIR)/usr/bin/
	GOFLAGS=-mod=vendor GOPROXY=off GOAMD64=$(PIKA_GOAMD64) \
		go build -ldflags="-s -w" -o $(DESTDIR)/usr/bin/pikman -buildvcs=false
	chmod 755 $(DESTDIR)/usr/bin/pikman