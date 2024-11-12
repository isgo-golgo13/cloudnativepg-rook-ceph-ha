package svckit

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"time"

	"cnpg-writersvc/datarepository"

	"github.com/jmoiron/sqlx"
)

type InsertRequest struct {
	GameName     string  `json:"game_name"`
	PlayerName   string  `json:"player_name"`
	Email        string  `json:"email"`
	TicketNumber string  `json:"ticket_number"`
	Status       string  `json:"status"`
	PrizeAmount  float64 `json:"prize_amount"`
}

var repo *datarepository.Repository

func InitRepository(db *sqlx.DB) {
	repo = datarepository.NewRepository(db)
}

func InsertHandler(w http.ResponseWriter, r *http.Request) {
	var req InsertRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid payload", http.StatusBadRequest)
		return
	}

	// Insert Game
	gameID, err := repo.InsertGame(datarepository.Game{
		GameName:  req.GameName,
		StartTime: time.Now(),
		EndTime:   time.Now().Add(2 * time.Hour),
		Status:    req.Status,
	})
	if err != nil {
		http.Error(w, "Failed to insert game", http.StatusInternalServerError)
		return
	}

	// Insert Player
	playerID, err := repo.InsertPlayer(datarepository.Player{
		PlayerName: req.PlayerName,
		Email:      req.Email,
		JoinDate:   time.Now(),
	})
	if err != nil {
		http.Error(w, "Failed to insert player", http.StatusInternalServerError)
		return
	}

	// Insert Ticket
	err = repo.InsertTicket(datarepository.Ticket{
		GameID:       sql.NullString{String: gameID, Valid: true},
		PurchaseTime: time.Now(),
		PlayerID:     sql.NullString{String: playerID, Valid: true},
		TicketNumber: req.TicketNumber,
		Status:       req.Status,
		PrizeAmount:  req.PrizeAmount,
	})
	if err != nil {
		http.Error(w, "Failed to insert ticket", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusCreated)
}
