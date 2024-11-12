package main

import (
	"cnpg-writersvc/svckit" // Adjust this path if needed
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	// Create a new router
	r := svckit.NewRouter()

	// Set up the server
	srv := &http.Server{
		Addr:    ":8080",
		Handler: r,
	}

	// Create a channel to listen for interrupt or termination signals
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	// Start the server in a goroutine
	go func() {
		log.Println("Starting server on :8080")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Could not listen on :8080: %v\n", err)
		}
	}()

	// Block until a signal is received
	<-stop

	// Graceful shutdown
	log.Println("Shutting down server...")

	// Create a deadline to wait for active connections to finish
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Attempt a graceful shutdown
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exiting")
}
