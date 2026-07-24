package com.notesbuddy.service;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Service;

import java.util.concurrent.TimeUnit;

@Service
public class MetricsService {

    private final MeterRegistry registry;
    private final Counter commandsIngested;
    private final Counter commandsSkipped;
    private final Counter commandsFailed;
    private final Counter searchRequests;
    private final Counter tagRequests;
    private final Timer searchLatency;
    private final Counter solutionsShown;

    public MetricsService(MeterRegistry registry) {
        this.registry = registry;
        this.commandsIngested = Counter.builder("notesbuddy.commands.ingested")
            .description("Total commands successfully ingested")
            .register(registry);
        this.commandsSkipped = Counter.builder("notesbuddy.commands.skipped")
            .description("Commands skipped (junk)")
            .register(registry);
        this.commandsFailed = Counter.builder("notesbuddy.commands.failed")
            .description("Commands with non-zero exit code")
            .register(registry);
        this.searchRequests = Counter.builder("notesbuddy.search.requests")
            .description("Total search queries executed")
            .register(registry);
        this.tagRequests = Counter.builder("notesbuddy.tag.requests")
            .description("Total tag assignments")
            .register(registry);
        this.searchLatency = Timer.builder("notesbuddy.search.latency")
            .description("Search query execution time")
            .publishPercentiles(0.5, 0.95, 0.99)
            .register(registry);
        this.solutionsShown = Counter.builder("notesbuddy.solutions.shown")
            .description("Solution cards returned to dashboard")
            .register(registry);
    }

    public void recordIngested(String category) {
        commandsIngested.increment();
        Counter.builder("notesbuddy.commands.by_category")
            .tag("category", category)
            .description("Commands by category")
            .register(registry)
            .increment();
    }

    public void recordSkipped() {
        commandsSkipped.increment();
    }

    public void recordFailed() {
        commandsFailed.increment();
    }

    public void recordSearch(long durationMillis) {
        searchRequests.increment();
        searchLatency.record(durationMillis, TimeUnit.MILLISECONDS);
    }

    public void recordTag() {
        tagRequests.increment();
    }

    public void recordSolutions(int count) {
        solutionsShown.increment(count);
    }
}