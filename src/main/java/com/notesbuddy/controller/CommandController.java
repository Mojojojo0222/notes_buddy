package com.notesbuddy.controller;

import com.notesbuddy.model.Command;
import com.notesbuddy.repository.CommandRepository;
import com.notesbuddy.service.SummaryService;
import com.notesbuddy.service.SessionService;
import org.springframework.data.domain.Sort;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

@RestController
public class CommandController {

    private final CommandRepository repo;
    private final SummaryService summaryService;
    private final SessionService sessionService;

    public CommandController(CommandRepository repo, SummaryService summaryService, SessionService sessionService) {
        this.repo           = repo;
        this.summaryService = summaryService;
        this.sessionService = sessionService;
    }

    @GetMapping("/commands/all")
    public List<Command> all() {
        return repo.findAll(Sort.by(Sort.Direction.ASC, "savedAt"));
    }

    @GetMapping("/summary")
    public Map<String, Object> summary() {
        return summaryService.getDailySummary();
    }

    @GetMapping("/sessions")
    public List<Map<String, Object>> sessions() {
        return sessionService.getSessionsWithCommands();
    }
}
