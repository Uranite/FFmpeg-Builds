import os
import subprocess
import glob
import re
from pathlib import Path
import shutil
import tempfile

def get_script_vars(content):
    """Parse script content to extract variables."""
    vars_dict = {}
    for line in content.splitlines():
        # Match variable assignments like SCRIPT_REPO="value"
        match = re.match(r'^(\w+)=["\'](.*)["\']$', line.strip())
        if match:
            vars_dict[match.group(1)] = match.group(2)
    return vars_dict

def update_script_content(filepath, var_name, new_value):
    """Update a variable in the script file."""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Create the new variable assignment line
    new_line = f'{var_name}="{new_value}"'
    
    # Replace the existing line using regex to match the variable assignment
    pattern = f'^{var_name}=.*$'
    updated_content = re.sub(pattern, new_line, content, flags=re.MULTILINE)
    
    with open(filepath, 'w', encoding='utf-8', newline='\n') as f:
        f.write(updated_content)

def get_git_default_branch(repo_url):
    """Get the default branch name for a Git repository."""
    try:
        result = subprocess.run(
            ['git', 'remote', 'show', repo_url],
            capture_output=True,
            text=True,
            check=True
        )
        for line in result.stdout.splitlines():
            if "HEAD branch:" in line:
                return line.split(":")[-1].strip()
    except subprocess.CalledProcessError:
        return None
    return None

def check_git_repo(repo_url, current_commit, branch=None, tag_filter=None):
    """Check for updates in a Git repository."""
    try:
        if tag_filter:
            # Get latest matching tag
            result = subprocess.run(
                ['git', 'ls-remote', '--tags', '--refs', repo_url, f'refs/tags/{tag_filter}'],
                capture_output=True,
                text=True,
                check=True
            )
            commits = result.stdout.strip().splitlines()
            if commits:
                # Get the last tag (assuming they're sorted)
                new_commit = commits[-1].split()[0]
                return new_commit
        else:
            if not branch:
                branch = get_git_default_branch(repo_url)
                if not branch:
                    return None
                
            result = subprocess.run(
                ['git', 'ls-remote', '--heads', repo_url, f'refs/heads/{branch}'],
                capture_output=True,
                text=True,
                check=True
            )
            if result.stdout.strip():
                return result.stdout.split()[0]
    except subprocess.CalledProcessError:
        return None
    return None

def check_svn_repo(repo_url, current_rev):
    """Check for updates in an SVN repository."""
    try:
        # First try a quick check to see if authentication is required
        result = subprocess.run(
            ['svn', 'info', '--non-interactive', repo_url],
            capture_output=True,
            text=True
        )
        
        # If authentication is required, skip this repo
        if "Authentication required" in result.stderr or "Username:" in result.stderr:
            print(f"Skipping {repo_url} - authentication required")
            return None
            
        # If we got here, no authentication required
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if line.startswith('Revision:'):
                    return line.split()[-1].strip()
    except subprocess.CalledProcessError:
        return None
    return None

def check_hg_repo(repo_url, current_hgrev):
    """Check for updates in a Mercurial repository."""
    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            # Initialize temporary repo
            subprocess.run(['hg', 'init'], cwd=temp_dir, check=True)
            
            # Get latest revision
            result = subprocess.run(
                ['hg', 'in', '-f', '-n', '-l', '1', repo_url],
                capture_output=True,
                text=True,
                cwd=temp_dir,
                check=True
            )
            
            for line in result.stdout.splitlines():
                if 'changeset' in line:
                    return line.split(':')[2].strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return None

def process_script(script_path):
    """Process a single script file."""
    print(f"Processing {script_path}")
    
    with open(script_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    vars_dict = get_script_vars(content)
    
    if 'SCRIPT_SKIP' in vars_dict:
        return
    
    for i in [''] + list(range(2, 10)):
        suffix = str(i) if i else ''
        
        repo_var = f'SCRIPT_REPO{suffix}'
        commit_var = f'SCRIPT_COMMIT{suffix}'
        rev_var = f'SCRIPT_REV{suffix}'
        hgrev_var = f'SCRIPT_HGREV{suffix}'
        branch_var = f'SCRIPT_BRANCH{suffix}'
        tagfilter_var = f'SCRIPT_TAGFILTER{suffix}'
        
        repo = vars_dict.get(repo_var)
        if not repo:
            if not suffix:
                # Mark scripts without repo source for manual check
                with open(script_path, 'a', encoding='utf-8', newline='\n') as f:
                    f.write('\nxxx_CHECKME_xxx\n')
                print("Needs manual check.")
            break
        
        current_commit = vars_dict.get(commit_var)
        current_rev = vars_dict.get(rev_var)
        current_hgrev = vars_dict.get(hgrev_var)
        current_branch = vars_dict.get(branch_var)
        current_tagfilter = vars_dict.get(tagfilter_var)
        
        if current_rev:  # SVN
            print(f"Checking svn rev for {repo}...")
            new_rev = check_svn_repo(repo, current_rev)
            if new_rev and new_rev != current_rev:
                print(f"Updating {script_path}")
                update_script_content(script_path, rev_var, new_rev)
                
        elif current_hgrev:  # Mercurial
            print(f"Checking hg rev for {repo}...")
            new_hgrev = check_hg_repo(repo, current_hgrev)
            if new_hgrev and new_hgrev != current_hgrev:
                print(f"Updating {script_path}")
                update_script_content(script_path, hgrev_var, new_hgrev)
                
        elif current_commit:  # Git
            print(f"Checking git commit for {repo}...")
            new_commit = check_git_repo(repo, current_commit, current_branch, current_tagfilter)
            if new_commit and new_commit != current_commit:
                print(f"Updating {script_path}")
                update_script_content(script_path, commit_var, new_commit)
                
        else:
            # Mark scripts with unknown layout for manual check
            with open(script_path, 'a', encoding='utf-8', newline='\n') as f:
                f.write('\nxxx_CHECKME_UNKNOWN_xxx\n')
            print("Unknown layout. Needs manual check.")
            break

def main():
    # Get the directory containing this script
    script_dir = Path(__file__).parent
    
    # Change to the parent directory
    os.chdir(script_dir.parent)
    
    # Process all .sh files in scripts.d directory and its subdirectories
    for script_path in glob.glob('scripts.d/**/*.sh', recursive=True):
        try:
            process_script(script_path)
            print()
        except Exception as e:
            print(f"Error processing {script_path}: {e}\n")

if __name__ == '__main__':
    main()