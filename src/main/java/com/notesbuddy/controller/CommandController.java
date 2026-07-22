package com.notesbuddy.controller;

import com.notesbuddy.model.Command;
import com.notesbuddy.repository.CommandRepository;
import com.notesbuddy.service.CommandService;
import com.notesbuddy.service.SummaryService;
import com.notesbuddy.service.SessionService;
import org.springframework.data.domain.Sort;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@RestController
public class CommandController {

    private final CommandRepository repo;
    private final SummaryService summaryService;
    private final SessionService sessionService;
    private final CommandService commandService;

    public CommandController(CommandRepository repo, SummaryService summaryService,
                             SessionService sessionService, CommandService commandService) {
        this.repo           = repo;
        this.summaryService = summaryService;
        this.sessionService = sessionService;
        this.commandService = commandService;
    }

    @GetMapping("/commands/all")
    public List<Command> all() {
        return repo.findAll(Sort.by(Sort.Direction.ASC, "savedAt"));
    }

    @GetMapping("/summary")
    public Map<String, Object> summary() {
        return summaryService.getDailySummary();
    }

    @GetMapping("/summary/weekly")
    public Map<String, Object> weeklySummary() {
        return summaryService.getWeeklySummary();
    }

    @GetMapping("/sessions")
    public List<Map<String, Object>> sessions() {
        return sessionService.getSessionsWithCommands();
    }

    @GetMapping("/commands/by-date")
    public List<Command> byDate(@RequestParam String date) {
        java.time.LocalDate day = java.time.LocalDate.parse(date);
        java.time.LocalDateTime start = day.atStartOfDay();
        java.time.LocalDateTime end = day.plusDays(1).atStartOfDay();
        return repo.findBySavedAtBetweenOrderBySavedAtAsc(start, end);
    }

    // Ingestion endpoint — called by .bashrc curl after every terminal command
    // Accepts: text, workingDir, repoName, timestamp, exitCode (all as request params)
    @PostMapping("/ingest")
    public ResponseEntity<String> ingest(
            @RequestParam String text,
            @RequestParam(defaultValue = "") String workingDir,
            @RequestParam(defaultValue = "none") String repoName,
            @RequestParam(defaultValue = "") String timestamp,
            @RequestParam(defaultValue = "") String exitCode) {

        Command saved = commandService.ingest(text, workingDir, repoName, timestamp, exitCode);
        if (saved == null) return ResponseEntity.ok("skipped");
        return ResponseEntity.ok("saved");
    }

    // Tag a command
    @PostMapping("/commands/{id}/tag")
    public ResponseEntity<String> tagCommand(@PathVariable Long id, @RequestParam String tag) {
        Command cmd = repo.findById(id).orElse(null);
        if (cmd == null) return ResponseEntity.notFound().build();
        cmd.setTag(tag.isBlank() ? null : tag);
        repo.save(cmd);
        return ResponseEntity.ok("tagged");
    }
}
