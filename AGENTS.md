# Development conventions

The project is still in an exploratory phase. Data structures, database tables, interfaces, and module boundaries are not yet settled; change them directly to match the current design.

Do not retain compatibility code paths for superseded designs. Do not design or maintain migration workflows. Maintain only the current PostgreSQL schema. When it changes, rebuild the local development database as needed, without introducing versioned migrations, upgrade chains, or migration frameworks.

During development, do not write tests in advance or introduce test frameworks. Run the application locally; containerize only middleware.
