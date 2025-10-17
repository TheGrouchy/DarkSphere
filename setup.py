from setuptools import setup, find_packages

setup(
    name="darkspere",
    version="1.0.0",
    description="SMS-to-Agent Bridge Platform",
    author="Darkspere Team",
    packages=find_packages(where="src"),
    package_dir={"": "src"},
    python_requires=">=3.8",
    install_requires=[
        "flask>=2.0.0",
        "flask-cors>=3.0.0",
        "psycopg2-binary>=2.9.0",
        "redis>=4.0.0",
        "stripe>=5.0.0",
        "bcrypt>=4.0.0",
        "python-json-logger>=2.0.0",
    ],
    extras_require={
        "dev": [
            "pytest>=7.0.0",
            "pytest-cov>=4.0.0",
            "black>=23.0.0",
            "flake8>=6.0.0",
        ]
    },
)
