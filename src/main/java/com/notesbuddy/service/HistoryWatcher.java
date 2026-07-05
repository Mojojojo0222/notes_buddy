package com.notesbuddy.service;

import com.notesbuddy.model.Command;
import com.notesbuddy.model.WatcherState;
import com.notesbuddy.repository.CommandRepository;
import com.notesbuddy.repository.WatcherStateRepository;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.time.format.DateTimeParseException;
import java.util.List;

@Service
public class HistoryWatcher {

    // our own clean log file — bash writes one line per command: /path/to/dir|command
    private static final Path LOG_FILE =
        Path.of(System.getProperty("user.home"), ".notes_buddy_log");

    private final CommandRepository repo;
    private final WatcherStateRepository stateRepo;

    public HistoryWatcher(CommandRepository repo, WatcherStateRepository stateRepo) {
        this.repo = repo;
        this.stateRepo = stateRepo;
    }

    @Scheduled(fixedDelay = 10000)
    public void scan() throws IOException {
        if (!Files.exists(LOG_FILE)) {
            System.out.println("Waiting for log file: " + LOG_FILE);
            return;
        }

        WatcherState state = stateRepo.findById(1L).orElse(new WatcherState());
        List<String> lines = Files.readAllLines(LOG_FILE);
        List<String> newLines = lines.subList(state.getLastLineCount(), lines.size());

        state.setLastLineCount(lines.size());
        stateRepo.save(state);

        for (String line : newLines) {
            String[] parts = line.split("\\|", 4);

            String timestamp, dir, repoName, command;

            // new format: timestamp|dir|repo|command (4 parts)
            // old format: dir|repo|command (3 parts) — fallback for existing log lines
            if (parts.length == 4) {
                timestamp = parts[0].trim();
                dir       = parts[1].trim();
                repoName  = parts[2].trim();
                command   = parts[3].trim();
            } else if (parts.length == 3) {
                timestamp = null;
                dir       = parts[0].trim();
                repoName  = parts[1].trim();
                command   = parts[2].trim();
            } else {
                continue;
            }

            if (isJunk(command)) continue;

            Command cmd = new Command(command, detectCategory(command), dir, repoName);
            if (timestamp != null) {
                try { cmd.setSavedAt(LocalDateTime.parse(timestamp)); }
                catch (DateTimeParseException ignored) {}
            }
            repo.save(cmd);
            System.out.println("Saved [" + dir + "] [" + repoName + "]: " + command);
        }
    }

    private boolean isJunk(String command) {
        if (command.isEmpty()) return true;
        if (command.startsWith("#")) return true;
        if (command.startsWith("[200~")) return true;  // bracketed paste artifact from terminal
        if (command.contains("=") && !command.contains(" ")) return true;
        if (command.length() < 2) return true;
        return false;
    }

    private String detectCategory(String command) {
        String c = command.toLowerCase();
        if (c.startsWith("git "))                                         return "git";
        if (c.startsWith("docker ") || c.startsWith("docker-compose "))  return "docker";
        if (c.startsWith("kubectl ") || c.startsWith("helm "))           return "kubernetes";
        if (c.startsWith("terraform ") || c.startsWith("tf "))           return "terraform";
        if (c.startsWith("mvn ") || c.startsWith("gradle "))             return "build";
        if (c.startsWith("ls") || c.startsWith("cd ") || c.startsWith("cp ")
            || c.startsWith("mv ") || c.startsWith("rm ") || c.startsWith("mkdir ")) return "files";
        if (c.startsWith("ssh ") || c.startsWith("scp ") || c.startsWith("curl ")
            || c.startsWith("wget ") || c.startsWith("ping "))           return "network";
        if (c.startsWith("cat ") || c.startsWith("grep ") || c.startsWith("tail ")
            || c.startsWith("head ") || c.startsWith("nano ") || c.startsWith("vim ")) return "editor";
        return "other";
    }
}
