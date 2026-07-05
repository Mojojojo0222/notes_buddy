package com.notesbuddy.model;

import jakarta.persistence.*;
import java.time.LocalDateTime;

@Entity
public class Session {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    private LocalDateTime startTime;   // time of first command in session
    private LocalDateTime endTime;     // time of last command in session
    private int commandCount;
    private String categories;         // comma-separated: "git,docker,kubernetes"

    public Session() {}

    public Session(LocalDateTime startTime, LocalDateTime endTime, int commandCount, String categories) {
        this.startTime    = startTime;
        this.endTime      = endTime;
        this.commandCount = commandCount;
        this.categories   = categories;
    }

    public Long getId()                  { return id; }
    public LocalDateTime getStartTime()  { return startTime; }
    public LocalDateTime getEndTime()    { return endTime; }
    public int getCommandCount()         { return commandCount; }
    public String getCategories()        { return categories; }
}
