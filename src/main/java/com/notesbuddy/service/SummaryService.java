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
        LocalDate today = LocalDate.now();
        List<Command> todayCommands = getCommandsForDate(today);

        return buildSummary(today.toString(), todayCommands);
    }

    public Map<String, Object> getWeeklySummary() {
        LocalDate today = LocalDate.now();
        LocalDate weekAgo = today.minusDays(7);
        List<Command> weekCommands = repo.findBySavedAtBetweenOrderBySavedAtAsc(
            weekAgo.atStartOfDay(), today.plusDays(1).atStartOfDay());

        Map<String, Object> summary = buildSummary(weekAgo + " — " + today, weekCommands);
        long errorCount = weekCommands.stream()
            .filter(c -> c.getExitCode() != null && c.getExitCode() != 0)
            .count();
        summary.put("errorCount", errorCount);
        return summary;
    }

    private List<Command> getCommandsForDate(LocalDate date) {
        return repo.findAll(Sort.by(Sort.Direction.ASC, "savedAt"))
            .stream()
            .filter(c -> c.getSavedAt().toLocalDate().equals(date))
            .toList();
    }

    private Map<String, Object> buildSummary(String label, List<Command> cmds) {
        Map<String, Long> frequency = cmds.stream()
            .collect(Collectors.groupingBy(Command::getText, Collectors.counting()));

        String mostUsed = frequency.entrySet().stream()
            .max(Map.Entry.comparingByValue())
            .map(e -> e.getKey() + " (" + e.getValue() + " times)")
            .orElse("none");

        List<String> topics = cmds.stream()
            .map(Command::getCategory)
            .filter(Objects::nonNull)
            .distinct()
            .sorted()
            .toList();

        Map<String, Object> summary = new LinkedHashMap<>();
        summary.put("date", label);
        summary.put("totalCommands", cmds.size());
        summary.put("topicsTouched", topics);
        summary.put("mostUsed", mostUsed);
        summary.put("commands", cmds);
        return summary;
    }
}
