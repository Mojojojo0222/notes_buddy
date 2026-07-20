package com.notesbuddy.model;

import jakarta.persistence.*;
import java.time.LocalDateTime;

@Entity
public class Command {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(length = 2000)
    private String text;
    private String category;
    @Column(length = 1000)
    private String workingDir;
    private String repoName;       // git repo name, "none" if not inside a git repo
    private LocalDateTime savedAt;

    public Command() {}

    public Command(String text, String category, String workingDir, String repoName) {
        this.text = text;
        this.category = category;
        this.workingDir = workingDir;
        this.repoName = repoName;
        this.savedAt = LocalDateTime.now();
    }

    public Long getId() { return id; }
    public String getText() { return text; }
    public String getCategory() { return category; }
    public String getWorkingDir() { return workingDir; }
    public String getRepoName() { return repoName; }
    public LocalDateTime getSavedAt() { return savedAt; }
    public void setSavedAt(LocalDateTime savedAt) { this.savedAt = savedAt; }
}
