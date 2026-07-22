package com.notesbuddy.service;

import com.notesbuddy.model.WatcherState;
import com.notesbuddy.repository.WatcherStateRepository;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

@Service
public class HistoryWatcher {

    private static final Path LOG_FILE =
        Path.of(System.getProperty("user.home"), ".notes_buddy_log");

    private final CommandService commandService;
    private final WatcherStateRepository stateRepo;

    public HistoryWatcher(CommandService commandService, WatcherStateRepository stateRepo) {
        this.commandService = commandService;
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
            String[] parts = line.split("\\|", 5);

            String timestamp, dir, repoName, command, exitCodeStr;

            if (parts.length == 5) {
                timestamp   = parts[0].trim();
                dir         = parts[1].trim();
                repoName    = parts[2].trim();
                command     = parts[3].trim();
                exitCodeStr = parts[4].trim();
            } else if (parts.length == 4) {
                timestamp   = parts[0].trim();
                dir         = parts[1].trim();
                repoName    = parts[2].trim();
                command     = parts[3].trim();
                exitCodeStr = null;
            } else if (parts.length == 3) {
                timestamp   = null;
                dir         = parts[0].trim();
                repoName    = parts[1].trim();
                command     = parts[2].trim();
                exitCodeStr = null;
            } else {
                continue;
            }

            commandService.ingest(command, dir, repoName, timestamp, exitCodeStr);
        }
    }
}
