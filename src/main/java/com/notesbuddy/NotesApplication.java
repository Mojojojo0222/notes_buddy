package com.notesbuddy;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling  // needed so HistoryWatcher can run automatically every few seconds
public class NotesApplication {
    public static void main(String[] args) {
        SpringApplication.run(NotesApplication.class, args);
    }
}
