package com.notesbuddy.model;

import jakarta.persistence.*;
import java.time.LocalDateTime;

@Entity
public class Command {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    private String text;
    private String category;
    private String workingDir;     // which folder the command was run from
    private LocalDateTime savedAt;

    public Command() {}

    public Command(String text, String category, String workingDir) {
        this.text = text;
        this.category = category;
        this.workingDir = workingDir;
        this.savedAt = LocalDateTime.now();
    }

    public Long getId() { return id; }
    public String getText() { return text; }
    public String getCategory() { return category; }
    public String getWorkingDir() { return workingDir; }
    public LocalDateTime getSavedAt() { return savedAt; }
}
