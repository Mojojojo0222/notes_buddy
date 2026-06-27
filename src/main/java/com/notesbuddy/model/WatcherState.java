package com.notesbuddy.model;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;

@Entity
public class WatcherState {

    @Id
    private Long id = 1L; // only ever one row, id is always 1

    private int lastLineCount;

    public WatcherState() {}

    public int getLastLineCount() { return lastLineCount; }
    public void setLastLineCount(int count) { this.lastLineCount = count; }
}
