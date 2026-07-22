package com.notesbuddy.repository;

import com.notesbuddy.model.Command;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.List;

public interface CommandRepository extends JpaRepository<Command, Long> {
    List<Command> findAllByOrderBySavedAtAsc();
    List<Command> findBySavedAtBetweenOrderBySavedAtAsc(java.time.LocalDateTime start, java.time.LocalDateTime end);
}
