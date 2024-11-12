package svckit

import (
	"github.com/go-chi/chi"
	"github.com/jmoiron/sqlx"
)

func NewRouter(db *sqlx.DB) *chi.Mux {
	InitRepository(db)
	r := chi.NewRouter()
	r.Post("/insert", InsertHandler)
	return r
}
