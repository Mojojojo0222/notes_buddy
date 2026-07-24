package com.notesbuddy.service;

import com.notesbuddy.model.Command;
import com.notesbuddy.repository.CommandRepository;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;

@Service
public class CommandService {

    private final CommandRepository repo;
    private final MetricsService metrics;

    public CommandService(CommandRepository repo, MetricsService metrics) {
        this.repo = repo;
        this.metrics = metrics;
    }

    public Command ingest(String text, String workingDir, String repoName, String timestamp, String exitCodeStr) {
        if (isJunk(text)) {
            metrics.recordSkipped();
            return null;
        }

        Command cmd = new Command(text, detectCategory(text), workingDir, repoName);
        if (timestamp != null && !timestamp.isBlank()) {
            try { cmd.setSavedAt(LocalDateTime.parse(timestamp)); }
            catch (Exception ignored) {}
        }
        if (exitCodeStr != null && !exitCodeStr.isBlank()) {
            try {
                int code = Integer.parseInt(exitCodeStr);
                cmd.setExitCode(code);
                if (code != 0) metrics.recordFailed();
            }
            catch (Exception ignored) {}
        }
        repo.save(cmd);
        metrics.recordIngested(cmd.getCategory());
        System.out.println("Ingested [" + workingDir + "] [" + repoName + "]: " + text);
        return cmd;
    }

    public boolean isJunk(String command) {
        if (command == null || command.isBlank()) return true;
        if (command.startsWith("#")) return true;
        if (command.startsWith("[200~")) return true;
        if (command.contains("=") && !command.contains(" ")) return true;
        if (command.length() < 2) return true;
        return false;
    }

    public String detectCategory(String command) {
        String c = command.toLowerCase();
        if (c.startsWith("git "))                                        return "git";
        if (c.startsWith("docker ") || c.startsWith("docker-compose ")) return "docker";
        if (c.startsWith("kubectl ") || c.startsWith("helm "))          return "kubernetes";
        if (c.startsWith("terraform ") || c.startsWith("tf "))          return "terraform";
        if (c.startsWith("mvn ") || c.startsWith("gradle "))            return "build";
        if (c.startsWith("ls") || c.startsWith("cd ") || c.startsWith("cp ")
            || c.startsWith("mv ") || c.startsWith("rm ") || c.startsWith("mkdir ")) return "files";
        if (c.startsWith("ssh ") || c.startsWith("scp ") || c.startsWith("curl ")
            || c.startsWith("wget ") || c.startsWith("ping "))          return "network";
        if (c.startsWith("cat ") || c.startsWith("grep ") || c.startsWith("tail ")
            || c.startsWith("head ") || c.startsWith("nano ") || c.startsWith("vim ")) return "editor";
        return "other";
    }
}
