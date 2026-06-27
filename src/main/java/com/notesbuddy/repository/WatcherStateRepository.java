package com.notesbuddy.repository;

import com.notesbuddy.model.WatcherState;
import org.springframework.data.jpa.repository.JpaRepository;

public interface WatcherStateRepository extends JpaRepository<WatcherState, Long> {
}
