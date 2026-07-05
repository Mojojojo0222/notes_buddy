package com.notesbuddy.service;

import com.notesbuddy.model.Command;
import com.notesbuddy.model.Session;
import com.notesbuddy.repository.CommandRepository;
import com.notesbuddy.repository.SessionRepository;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.*;
import java.util.stream.Collectors;

@Service
public class SessionService {

    private static final int SESSION_GAP_MINUTES = 30;

    private final CommandRepository commandRepo;
    private final SessionRepository sessionRepo;

    public SessionService(CommandRepository commandRepo, SessionRepository sessionRepo) {
        this.commandRepo = commandRepo;
        this.sessionRepo = sessionRepo;
    }

    // Returns sessions with their commands — used by the dashboard
    public List<Map<String, Object>> getSessionsWithCommands() {
        List<Command> all = commandRepo.findAllByOrderBySavedAtAsc();

        if (all.isEmpty()) return Collections.emptyList();

        // Split commands into session buckets
        List<List<Command>> buckets = new ArrayList<>();
        List<Command> current = new ArrayList<>();

        for (Command cmd : all) {
            if (current.isEmpty()) {
                current.add(cmd);
            } else {
                Command prev = current.get(current.size() - 1);
                long gap = Duration.between(prev.getSavedAt(), cmd.getSavedAt()).toMinutes();
                if (gap > SESSION_GAP_MINUTES) {
                    buckets.add(current);
                    current = new ArrayList<>();
                }
                current.add(cmd);
            }
        }
        buckets.add(current); // last bucket

        // Build response — newest session first
        List<Map<String, Object>> result = new ArrayList<>();
        for (int i = buckets.size() - 1; i >= 0; i--) {
            List<Command> bucket = buckets.get(i);
            result.add(buildSessionMap(bucket));
        }
        return result;
    }

    private Map<String, Object> buildSessionMap(List<Command> commands) {
        LocalDateTime start = commands.get(0).getSavedAt();
        LocalDateTime end   = commands.get(commands.size() - 1).getSavedAt();

        long durationMins = Duration.between(start, end).toMinutes();

        List<String> categories = commands.stream()
            .map(Command::getCategory)
            .filter(Objects::nonNull)
            .distinct()
            .sorted()
            .collect(Collectors.toList());

        Map<String, Object> map = new LinkedHashMap<>();
        map.put("startTime",    start);
        map.put("endTime",      end);
        map.put("durationMins", durationMins);
        map.put("commandCount", commands.size());
        map.put("categories",   categories);
        map.put("commands",     commands);
        return map;
    }
}
