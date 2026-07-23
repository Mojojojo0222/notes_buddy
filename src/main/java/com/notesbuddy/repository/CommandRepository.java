package com.notesbuddy.repository;

import com.notesbuddy.model.Command;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import java.util.List;

public interface CommandRepository extends JpaRepository<Command, Long> {
    List<Command> findAllByOrderBySavedAtAsc();
    List<Command> findBySavedAtBetweenOrderBySavedAtAsc(java.time.LocalDateTime start, java.time.LocalDateTime end);

    @Query("SELECT c FROM Command c WHERE " +
           "LOWER(c.text) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
           "LOWER(c.tag) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
           "LOWER(c.workingDir) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
           "LOWER(c.repoName) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
           "LOWER(c.category) LIKE LOWER(CONCAT('%', :query, '%')) " +
           "ORDER BY c.savedAt ASC")
    List<Command> searchCommands(@Param("query") String query);
}
