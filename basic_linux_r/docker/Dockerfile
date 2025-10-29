# Use Ubuntu as base image
FROM ubuntu:22.04

# Install dependencies in one layer
RUN apt-get update && apt-get install -y \
    curl \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Quarto
RUN curl -LO https://quarto.org/download/latest/quarto-linux-amd64.deb \
    && dpkg -i quarto-linux-amd64.deb \
    && rm quarto-linux-amd64.deb

# Install Python packages
RUN pip3 install --no-cache-dir pyyaml jupyter nbformat jupyterlab

# Set working directory
WORKDIR /workspace

# Copy the presentation file
COPY intro_to_linux.qmd /workspace/

# Render both HTML presentation and Jupyter notebook
RUN quarto render intro_to_linux.qmd && \
    quarto render intro_to_linux.qmd --to ipynb

# Expose ports
EXPOSE 8000 8888

# Start HTTP server and JupyterLab
CMD ["sh", "-c", "python3 -m http.server 8000 --directory /workspace & jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password=''"]