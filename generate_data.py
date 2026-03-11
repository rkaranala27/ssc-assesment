import os
import boto3
import pandas as pd
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
from datetime import datetime, timedelta

# Configuration for Mock S3
AWS_REGION = "us-east-1"
S3_ENDPOINT_URL = "http://127.0.0.1:5001"
BUCKET_NAME = "lakehouse-data-v2"

# Setup dummy AWS credentials so boto3/pyarrow connects to Moto
os.environ["AWS_ACCESS_KEY_ID"] = "test"
os.environ["AWS_SECRET_ACCESS_KEY"] = "test"
os.environ["AWS_DEFAULT_REGION"] = AWS_REGION

def init_mock_s3():
    """Create the mock bucket using boto3."""
    print(f"Connecting to Moto S3 at {S3_ENDPOINT_URL}...")
    s3_client = boto3.client("s3", endpoint_url=S3_ENDPOINT_URL)
    
    # Create bucket
    try:
        s3_client.create_bucket(Bucket=BUCKET_NAME)
        print(f"Bucket '{BUCKET_NAME}' created successfully.")
    except Exception as e:
        print(f"Bucket creation error (might already exist): {e}")

def generate_sample_data(num_rows=1000):
    """Generate mock dataframe with lakehouse schema."""
    print(f"Generating {num_rows} rows of sample data...")
    np.random.seed(42)
    
    # Generate dates over the last 30 days
    base_date = datetime.today()
    dates = [(base_date - timedelta(days=np.random.randint(0, 30))).strftime('%Y-%m-%d') for _ in range(num_rows)]
    
    # Generate client IDs, fund IDs, metrics
    client_ids = np.random.randint(100, 150, size=num_rows).astype(str)
    fund_ids = np.where(np.random.rand(num_rows) > 0.2, np.random.randint(1000, 1050, size=num_rows).astype(str), None)
    metric_names = np.random.choice(["AUM", "FLOW_IN", "FLOW_OUT", "REVENUE"], size=num_rows)
    metric_values = np.round(np.random.uniform(100.0, 50000.0, size=num_rows), 2)
    
    df = pd.DataFrame({
        "client_id": client_ids,
        "fund_id": fund_ids,
        "as_of_date": dates,
        "metric_name": metric_names,
        "metric_value": metric_values
    })
    
    return df

def upload_to_mock_s3(df):
    """Write DataFrame to Moto S3 as Parquet using local files + boto3."""
    print("Writing PyArrow Parquet to local temp directory, then uploading to Mock S3 via boto3...")
    
    table = pa.Table.from_pandas(df)

    # Write dataset to a local temporary directory
    tmp_dir = "mock_s3_dataset"
    if os.path.exists(tmp_dir):
        import shutil
        shutil.rmtree(tmp_dir)
    os.makedirs(tmp_dir, exist_ok=True)

    pq.write_to_dataset(
        table,
        root_path=tmp_dir,
        use_dictionary=True,
        compression="snappy",
    )

    # Upload all generated parquet files to the Moto S3 bucket using boto3
    print(f"Uploading Parquet files from '{tmp_dir}' to mock S3 bucket '{BUCKET_NAME}'...")
    s3_client = boto3.client("s3", endpoint_url=S3_ENDPOINT_URL)

    for root, _, files in os.walk(tmp_dir):
        for filename in files:
            if not filename.endswith(".parquet"):
                continue
            local_path = os.path.join(root, filename)
            # Place all files under the 'data/' prefix in the bucket
            relative_path = os.path.relpath(local_path, tmp_dir)
            s3_key = os.path.join("data", relative_path)
            print(f"Uploading {local_path} to s3://{BUCKET_NAME}/{s3_key} ...")
            s3_client.upload_file(local_path, BUCKET_NAME, s3_key)
    
    print("Data successfully generated and uploaded to Mock S3. Exiting generate_data.py now.")

if __name__ == "__main__":
    init_mock_s3()
    df = generate_sample_data(1000)
    upload_to_mock_s3(df)
