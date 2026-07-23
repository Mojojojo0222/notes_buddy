# Stage 1: Build React frontend
FROM node:20-alpine AS frontend-build

WORKDIR /frontend
COPY frontend/package*.json ./
RUN npm ci
COPY frontend/ .
RUN VITE_OUT_DIR=dist npm run build

# Stage 2: Build Spring Boot backend
FROM maven:3.9-eclipse-temurin-17 AS backend-build

WORKDIR /app

COPY pom.xml .
RUN mvn dependency:go-offline -q

# Copy React build output into Spring Boot's static resources directory
COPY --from=frontend-build /frontend/dist ./src/main/resources/static

COPY src ./src
RUN mvn package -DskipTests -q

# Stage 3: Runtime
FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

COPY --from=backend-build /app/target/notes-buddy-0.0.1.jar app.jar

EXPOSE 9098

VOLUME /root
VOLUME /app/notesbuddy-db

ENTRYPOINT ["java", "-jar", "app.jar"]
