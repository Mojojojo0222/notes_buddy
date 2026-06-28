FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /app

# If only source code changes (not dependencies), Maven download step is skipped.
COPY pom.xml .
RUN mvn dependency:go-offline -q


COPY src ./src
RUN mvn package -DskipTests -q

FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# Copy only the fat JAR from the build stage —
COPY --from=build /app/target/notes-buddy-0.0.1.jar app.jar

EXPOSE 9098

#Mount volumes
VOLUME /root

ENTRYPOINT ["java", "-jar", "app.jar"]
