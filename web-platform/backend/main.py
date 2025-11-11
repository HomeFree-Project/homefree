#!/usr/bin/env python3
"""
HomeFree Web Installer Backend
GraphQL API server for the HomeFree installation process
"""

import asyncio
import logging
from pathlib import Path
from typing import Optional

import strawberry
from strawberry.asgi import GraphQL
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from schema import Query, Mutation
from services.install import InstallationService

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Create FastAPI app
app = FastAPI(title="HomeFree Web Installer API")

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify exact origins
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Create Strawberry GraphQL schema
schema = strawberry.Schema(query=Query, mutation=Mutation)

# Mount GraphQL endpoint
graphql_app = GraphQL(schema)
app.add_route("/graphql", graphql_app)

# Serve static files (frontend build)
frontend_dist = Path(__file__).parent.parent / "dist"
if frontend_dist.exists():
    app.mount("/", StaticFiles(directory=str(frontend_dist), html=True), name="static")
else:
    logger.warning(f"Frontend dist directory not found: {frontend_dist}")

@app.on_event("startup")
async def startup_event():
    """Initialize services on startup"""
    logger.info("Starting HomeFree Web Installer API")
    # Initialize installation service
    InstallationService.initialize()

@app.on_event("shutdown")
async def shutdown_event():
    """Cleanup on shutdown"""
    logger.info("Shutting down HomeFree Web Installer API")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )
