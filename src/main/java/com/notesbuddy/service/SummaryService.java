package com.notesbuddy.service;

import com.notesbuddy.model.Command;
import com.notesbuddy.repository.CommandRepository;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;

import java.time.LocalDate;
import java.util.*;
import java.util.stream.Collectors;

@Service
public class SummaryService {

    private final CommandRepository repo;

    public SummaryService(CommandRepository repo) {
        this.repo = repo;
    }

    public Map<String, Object> getDailySummary() {
        // get all commands saved today
        LocalDate today = LocalDate.now();
        List<Command> todayCommands = repo.findAll(Sort.by(Sort.Direction.ASC, "savedAt"))
            .stream()
            .filter(c -> c.getSavedAt().toLocalDate().equals(today))
            .toList();

        // count how many times each command text appeared
        Map<String, Long> frequency = todayCommands.stream()
            .collect(Collectors.groupingBy(Command::getText, Collectors.counting()));

        // find the single most used command
        String mostUsed = frequency.entrySet().stream()
            .max(Map.Entry.comparingByValue())
            .map(e -> e.getKey() + " (" + e.getValue() + " times)")
            .orElse("none");

        // collect unique categories touched today
        List<String> topics = todayCommands.stream()
            .map(Command::getCategory)
            .distinct()
            .sorted()
            .toList();

        Map<String, Object> summary = new LinkedHashMap<>();
        summary.put("date", today.toString());
        summary.put("totalCommands", todayCommands.size());
        summary.put("topicsTouched", topics);
        summary.put("mostUsed", mostUsed);
        summary.put("commands", todayCommands); // full list for the UI

        return summary;
    }
}
