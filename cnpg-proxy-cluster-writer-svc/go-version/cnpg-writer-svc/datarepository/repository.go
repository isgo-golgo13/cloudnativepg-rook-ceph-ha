package datarepository

import (
	"database/sql"
	"log"
	"time"

	"github.com/jmoiron/sqlx"
)

type Game struct {
	GameName  string
	StartTime time.Time
	EndTime   time.Time
	Status    string
}

type Player struct {
	PlayerName string
	Email      string
	JoinDate   time.Time
}

type Ticket struct {
	GameID       sql.NullString
	PurchaseTime time.Time
	PlayerID     sql.NullString
	TicketNumber string
	Status       string
	PrizeAmount  float64
}

type Repository struct {
	DB *sqlx.DB
}

func NewRepository(db *sqlx.DB) *Repository {
	return &Repository{DB: db}
}

func (repo *Repository) InsertGame(game Game) (string, error) {
	var gameID string
	query := `
        INSERT INTO eql_games (game_name, start_time, end_time, status)
        VALUES ($1, $2, $3, $4)
        RETURNING game_id
    `
	err := repo.DB.QueryRow(query, game.GameName, game.StartTime, game.EndTime, game.Status).Scan(&gameID)
	if err != nil {
		log.Printf("Error inserting game: %v", err)
		return "", err
	}
	return gameID, nil
}

func (repo *Repository) InsertPlayer(player Player) (string, error) {
	var playerID string
	query := `
        INSERT INTO eql_game_players (player_name, email, join_date)
        VALUES ($1, $2, $3)
        RETURNING player_id
    `
	err := repo.DB.QueryRow(query, player.PlayerName, player.Email, player.JoinDate).Scan(&playerID)
	if err != nil {
		log.Printf("Error inserting player: %v", err)
		return "", err
	}
	return playerID, nil
}

func (repo *Repository) InsertTicket(ticket Ticket) error {
	query := `
        INSERT INTO eql_game_tickets (game_id, purchase_time, player_id, ticket_number, status, prize_amount)
        VALUES ($1, $2, $3, $4, $5, $6)
    `
	_, err := repo.DB.Exec(query, ticket.GameID, ticket.PurchaseTime, ticket.PlayerID, ticket.TicketNumber, ticket.Status, ticket.PrizeAmount)
	if err != nil {
		log.Printf("Error inserting ticket: %v", err)
	}
	return err
}
