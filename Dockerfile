# The server on Linux with the made-up demo week, for directories that start a server to read its tools (Glama).
# EventKit is macOS only: real calendars need the Mac app (see the README).
FROM swift:6.2-noble AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product apple-calendar-mcp --static-swift-stdlib \
    && cp "$(swift build -c release --show-bin-path)/apple-calendar-mcp" /usr/local/bin/

FROM ubuntu:24.04
# FoundationNetworking (linked by the MCP SDK) loads libcurl.
RUN apt-get update && apt-get install -y --no-install-recommends libcurl4 libxml2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/apple-calendar-mcp /usr/local/bin/apple-calendar-mcp
ENTRYPOINT ["apple-calendar-mcp", "--demo"]
