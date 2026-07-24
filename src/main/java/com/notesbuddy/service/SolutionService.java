package com.notesbuddy.service;

import com.notesbuddy.model.Command;
import com.notesbuddy.repository.CommandRepository;
import org.springframework.stereotype.Service;

import java.util.*;

@Service
public class SolutionService {

    private final CommandRepository repo;

    public SolutionService(CommandRepository repo) {
        this.repo = repo;
    }

    public List<Map<String, Object>> findSolutions() {
        List<Command> failed = repo.findByExitCodeNotNullAndExitCodeNotOrderBySavedAtAsc(0);
        if (failed.isEmpty()) return Collections.emptyList();

        Map<String, List<Command>> byText = new LinkedHashMap<>();
        for (Command c : failed) {
            byText.computeIfAbsent(c.getText(), k -> new ArrayList<>()).add(c);
        }

        List<Command> all = repo.findAllByOrderBySavedAtAsc();

        List<Map<String, Object>> solutions = new ArrayList<>();

        for (Map.Entry<String, List<Command>> entry : byText.entrySet()) {
            List<Command> occurrences = entry.getValue();
            if (occurrences.size() < 2) continue;

            Command latest = occurrences.get(occurrences.size() - 1);
            Command previous = occurrences.get(occurrences.size() - 2);

            String fix = null;

            for (Command c : occurrences) {
                if (c.getTag() != null && !c.getTag().isBlank()) {
                    fix = c.getTag();
                    break;
                }
            }

            if (fix == null) {
                fix = findFixFromNextCommands(all, previous);
            }

            Map<String, Object> card = new LinkedHashMap<>();
            card.put("errorText", entry.getKey());
            card.put("occurrences", occurrences.size());
            card.put("lastFailed", latest.getSavedAt().toString());
            card.put("errorCategory", latest.getCategory());
            card.put("fix", fix != null ? fix : "");
            solutions.add(card);
        }

        solutions.sort((a, b) -> Integer.compare((int) b.get("occurrences"), (int) a.get("occurrences")));
        return solutions;
    }

    private String findFixFromNextCommands(List<Command> all, Command failedCmd) {
        int idx = all.indexOf(failedCmd);
        if (idx < 0) return null;

        for (int i = idx + 1; i < all.size(); i++) {
            Command next = all.get(i);
            if (next.getText().equals(failedCmd.getText()) && next.getExitCode() != null && next.getExitCode() == 0) {
                return "retried successfully";
            }
            if (next.getExitCode() != null && next.getExitCode() != 0) continue;
            if (next.getText().startsWith("git ") || next.getText().startsWith("docker ") ||
                next.getText().startsWith("kubectl ") || next.getText().startsWith("terraform ") ||
                next.getText().startsWith("mvn ") || next.getText().startsWith("npm ") ||
                next.getText().startsWith("pip ")) {
                return next.getText();
            }
        }
        return null;
    }
}